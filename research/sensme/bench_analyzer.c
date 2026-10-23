#include "NegiSensMeCore.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef struct{pthread_mutex_t lock;size_t next,jobs;const unsigned char *expected;size_t expected_size;int16_t input[8192];uint64_t *checksums;atomic_int failed;} Pool;
static void *worker(void *context){
    Pool *p=context;
    for(;;){
        pthread_mutex_lock(&p->lock);size_t index=p->next++;pthread_mutex_unlock(&p->lock);if(index>=p->jobs)break;
        NegiSensMeAnalyzer *a=negi_sensme_analyzer_create();int ok=a!=NULL;
        const size_t frames=44100*310;
        for(size_t at=0;at<frames && ok;at+=4096){size_t n=frames-at;if(n>4096)n=4096;ok=negi_sensme_analyzer_write(a,p->input,n);}
        NegiSensMeAnalyzerSummary summary={0};size_t n=ok?negi_sensme_analyzer_finish(a,NULL,0,&summary):0;
        unsigned char *output=n?malloc(n):NULL;
        ok=ok && output && n==p->expected_size && summary.processed_frames==38016 && negi_sensme_analyzer_finish(a,output,n,NULL)==n && !memcmp(output,p->expected,n);
        uint64_t hash=1469598103934665603ULL;
        if(ok)for(size_t i=0;i<n;i++)hash=(hash^output[i])*1099511628211ULL;
        else atomic_fetch_add(&p->failed,1);
        p->checksums[index]=hash;free(output);negi_sensme_analyzer_destroy(a);
    }
    return NULL;
}
int main(int argc,char **argv){
    assert(argc==4);size_t workers=(size_t)atoi(argv[1]),jobs=(size_t)atoi(argv[2]);assert(workers>0 && workers<=16 && jobs>=workers);
    FILE *f=fopen(argv[3],"rb");assert(f);assert(!fseek(f,0,SEEK_END));long n=ftell(f);assert(n>0 && n<=200000);rewind(f);unsigned char *expected=malloc((size_t)n);assert(expected && fread(expected,1,(size_t)n,f)==(size_t)n);fclose(f);
    Pool p={0};assert(!pthread_mutex_init(&p.lock,NULL));p.jobs=jobs;p.expected=expected;p.expected_size=(size_t)n;p.checksums=calloc(jobs,sizeof(uint64_t));assert(p.checksums);
    uint32_t seed=0x39a17c11;for(int i=0;i<8192;i++){seed=1664525*seed+1013904223;p.input[i]=(int16_t)((int)(seed>>16)-32768);}
    pthread_t threads[16];struct timespec begin,end;assert(!clock_gettime(CLOCK_MONOTONIC,&begin));
    for(size_t i=0;i<workers;i++)assert(!pthread_create(threads+i,NULL,worker,&p));
    for(size_t i=0;i<workers;i++)assert(!pthread_join(threads[i],NULL));
    assert(!clock_gettime(CLOCK_MONOTONIC,&end));double elapsed=(double)(end.tv_sec-begin.tv_sec)+(end.tv_nsec-begin.tv_nsec)*1e-9;
    uint64_t checksum=0;for(size_t i=0;i<jobs;i++)checksum+=p.checksums[i];int failures=atomic_load(&p.failed);
#ifdef NEGI_SENSME_SCALAR
    const char *backend="C";
#else
    const char *backend="NEON";
#endif
    printf("{\"backend\":\"%s\",\"workers\":%zu,\"jobs\":%zu,\"inputSecondsPerJob\":310,\"elapsedSeconds\":%.9f,\"failed\":%d,\"checksum\":\"%llu\"}\n",backend,workers,jobs,elapsed,failures,(unsigned long long)checksum);
    pthread_mutex_destroy(&p.lock);free(p.checksums);free(expected);return failures?1:0;
}
