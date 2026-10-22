"""Local Media Go 3.2 / GNSDK 3.07 album metadata bridge.

Only text and selected result GDOs are submitted. No audio or tag writes.
Credentials, SDK logs and serialized users are never emitted.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def text(node, *paths):
    if node is not None:
        for path in paths:
            value = node.findtext(path)
            if value and value.strip():
                return value.strip()
    return ''


def artist_name(node):
    return text(node, 'ARTIST/NAME_OFFICIAL/DISPLAY', 'ARTIST/NAME', 'ARTIST')


def parse_covers(album):
    covers = []
    if album is None:
        return covers
    for content in album.findall('./CONTENT'):
        if text(content, 'TYPE') != 'gnsdk_content_image_cover':
            continue
        for asset in content.findall('./ASSET'):
            url = text(asset, 'URL')
            dimension = asset.get('DIMENSION', '').split('x')
            if not url or len(dimension) != 2 or not all(n.isdigit() for n in dimension):
                continue
            width, height = map(int, dimension)
            if not (0 < width <= 8192 and 0 < height <= 8192):
                continue
            count = asset.get('BYTES', '0')
            covers.append(dict(id=hashlib.sha256(url.encode()).hexdigest(), url=url,
                               size=asset.get('SIZE', ''), width=width, height=height,
                               estimatedBytes=int(count) if count.isdigit() else 0))
    return sorted(covers, key=lambda c: c['width'] * c['height'])[:24]


def parse_candidates(xml, title='', track_number='', serialized_albums=None):
    root = ET.fromstring(xml)
    serialized_albums = serialized_albums or {}
    def record(track, album, order):
        name = text(track, 'TITLE_OFFICIAL/DISPLAY', 'TITLE', 'TITLE/DISPLAY')
        genre = text(track, 'GENRE_LEVEL3', 'GENRE_LEVEL2', 'GENRE_LEVEL1', 'GENRE') or text(album, 'GENRE_LEVEL3', 'GENRE_LEVEL2', 'GENRE_LEVEL1', 'GENRE')
        patch = dict(title=name, artist=artist_name(track) or artist_name(album),
                     album=text(album, 'TITLE_OFFICIAL/DISPLAY', 'TITLE', 'TITLE/DISPLAY'),
                     track=text(track, 'TRACK_NUM', 'TRACK_NUMBER'), disc=text(album, 'DISC_IN_SET', 'DISC_NUM'),
                     year=text(album, 'YEAR', 'DATE') or text(track, 'YEAR'), genre=genre,
                     gracenoteID=text(track, 'GN_ID', 'GNID'))
        additional = {
            'ALBUMARTIST': artist_name(album), 'TRACKTOTAL': text(album, 'TRACK_COUNT'),
            'DISCTOTAL': text(album, 'TOTAL_IN_SET'), 'LABEL': text(album, 'LABEL'),
            'ORIGINALDATE': text(track, 'YEAR'), 'LANGUAGE': (album.get('LANG', '') if album is not None else '') or text(album, 'PACKAGE_LANG'),
            'ISRC': text(track, 'ISRC'), 'BARCODE': text(album, 'BARCODE', 'UPC'),
            'CATALOGNUMBER': text(album, 'CATALOG_NUM', 'CATALOG_NUMBER'),
            'COPYRIGHT': text(track, 'COPYRIGHT') or text(album, 'COPYRIGHT'),
        }
        compilation = text(album, 'COMPILATION')
        if compilation in ('Y', 'N', '1', '0'):
            additional['COMPILATION'] = '1' if compilation in ('Y', '1') else '0'
        for field, paths in {
            'ARTIST_ORIGIN': ('ORIGIN_LEVEL4', 'ORIGIN_LEVEL3', 'ORIGIN_LEVEL2', 'ORIGIN_LEVEL1'),
            'ARTIST_ERA': ('ERA_LEVEL3', 'ERA_LEVEL2', 'ERA_LEVEL1'),
            'ARTIST_TYPE': ('TYPE_LEVEL2', 'TYPE_LEVEL1'),
        }.items():
            additional[field] = text(track, *('ARTIST/CONTRIBUTOR/' + p for p in paths), *('ARTIST/' + p for p in paths)) or text(album, *('ARTIST/CONTRIBUTOR/' + p for p in paths), *('ARTIST/' + p for p in paths))
        for field, role in [('COMPOSER', 'composer'), ('LYRICIST', 'lyricist'), ('CONDUCTOR', 'conductor')]:
            names = []
            for parent in (track, album):
                if parent is None:
                    continue
                direct = text(parent, field)
                if direct:
                    names.append(direct)
                for credit in parent.findall('./CREDIT'):
                    roles = [credit.get('ROLE', ''), text(credit, 'ROLE', 'ROLE/DISPLAY')]
                    if any(role in r.casefold() for r in roles):
                        value = text(credit, 'NAME_OFFICIAL/DISPLAY', 'NAME/DISPLAY', 'NAME', 'CONTRIBUTOR/NAME_OFFICIAL/DISPLAY')
                        if value:
                            names.append(value)
            additional[field] = '; '.join(dict.fromkeys(names))
        patch['additionalFields'] = {k: v for k, v in additional.items() if v}
        covers = parse_covers(album)
        # Keep editions with different cover art even when their text fields coincide.
        identity = json.dumps([patch, [a['id'] for a in covers], order], ensure_ascii=False, sort_keys=True)
        return dict(id=hashlib.sha256(identity.encode()).hexdigest(), metadata=patch, artwork=covers,
                    sdkData=serialized_albums.get(order), fullResult=text(album, 'FULL_RESULT') == '1')
    found = []
    if root.tag == 'TRACK_RESPONSE':
        for track in root.findall('./TRACK'):
            for album in track.findall('./ALBUM') or [None]:
                found.append(record(track, album, album.get('ORD', '1') if album is not None else '1'))
    else:
        for album in root.findall('./ALBUM'):
            order = album.get('ORD', '1')
            matched = text(album, 'TRACK_MATCHED')
            for track in album.findall('./TRACK'):
                name = text(track, 'TITLE_OFFICIAL/DISPLAY', 'TITLE', 'TITLE/DISPLAY')
                number = text(track, 'TRACK_NUM', 'TRACK_NUMBER')
                if name and (not title or name.casefold() == title.casefold() or text(track, 'MATCHED') == '1' or track.get('MATCHED') == '1' or (number and number == (track_number or matched))):
                    found.append(record(track, album, order))
    return list({c['id']: c for c in found if c['metadata']['title']}.values())[:40]


def lookup(sdk_dir, config_file, user_file, request):
    if sys.platform != 'win32' or C.sizeof(C.c_void_p) != 4:
        raise RuntimeError('This bridge requires 32-bit Windows Python.')
    config = json.loads(config_file.read_text(encoding='utf-8'))
    U, P, S = C.c_uint32, C.c_void_p, C.c_char_p
    manager = C.CDLL(str(sdk_dir / 'gnsdk_manager.dll'))
    music = C.CDLL(str(sdk_dir / 'gnsdk_musicid.dll'))
    def bind(module, name, args, result=U):
        function = getattr(module, name); function.argtypes = args; function.restype = result
        return function
    def checked(code, phase):
        if code:
            raise RuntimeError(f'Gracenote {phase}: SDK error 0x{code:08x}')
    mgr, user, query, gdo, locale, rendered = P(), P(), P(), P(), P(), S()
    initialized = False
    try:
        license_data = config['license'].encode('utf-8')
        checked(bind(manager, 'gnsdk_manager_initialize', [C.POINTER(P), S, U])(C.byref(mgr), license_data, len(license_data)), 'initialize')
        initialized = True
        checked(bind(music, 'gnsdk_musicid_initialize', [P])(mgr), 'musicid_initialize')
        cid, tag, version = (config[k].encode('utf-8') for k in ('client_id', 'client_tag', 'client_version'))
        if user_file.is_file():
            checked(bind(manager, 'gnsdk_manager_user_create', [S, S, C.POINTER(P)])(user_file.read_bytes(), cid, C.byref(user)), 'user_create')
        else:
            serialized = S()
            checked(bind(manager, 'gnsdk_manager_user_register', [S, S, S, S, C.POINTER(S)])(b'gnsdk_userregmode_online', cid, tag, version, C.byref(serialized)), 'register')
            try:
                if not serialized:
                    raise RuntimeError('Gracenote returned no user registration.')
                user_file.write_bytes(serialized.value)
                checked(bind(manager, 'gnsdk_manager_user_create', [S, S, C.POINTER(P)])(serialized.value, cid, C.byref(user)), 'user_create')
            finally:
                if serialized: bind(manager, 'gnsdk_manager_string_free', [S])(serialized)
        sdk_version = bind(manager, 'gnsdk_manager_get_version', [], S)().decode('ascii', 'replace')
        if request.get('action') == 'probe':
            return dict(sdkVersion=sdk_version, ready=True, candidates=[])
        title = str(request.get('title', '')).strip()
        artist = str(request.get('artist', '')).strip()
        album = str(request.get('album', '')).strip()
        if not title or not (artist or album):
            raise ValueError('A title and either artist or album are required.')
        if any(len(s) > 1000 for s in (title, artist, album)):
            raise ValueError('Search text is too long.')
        # Optional display lists turn genre/artist descriptors into text. They contain no credentials.
        locale_file = user_file.with_name('locale-eng.dat')
        if locale_file.is_file():
            code = bind(manager, 'gnsdk_manager_locale_deserialize', [S, C.POINTER(P)])(locale_file.read_bytes(), C.byref(locale))
        else:
            code = 1
        if code:
            locale = P()
            code = bind(manager, 'gnsdk_manager_locale_load', [S, S, S, S, P, P, P, C.POINTER(P)])(b'gnsdk_locale_music', b'eng', b'gnsdk_region_global', b'gnsdk_desc_detailed', user, None, None, C.byref(locale))
            if not code:
                serialized = S()
                if not bind(manager, 'gnsdk_manager_locale_serialize', [P, C.POINTER(S)])(locale, C.byref(serialized)):
                    try: locale_file.write_bytes(serialized.value)
                    finally: bind(manager, 'gnsdk_manager_string_free', [S])(serialized)
        if locale:
            checked(bind(manager, 'gnsdk_manager_locale_set_group_default', [P])(locale), 'locale')
        checked(bind(music, 'gnsdk_musicid_query_create', [P, P, P, C.POINTER(P)])(user, None, None, C.byref(query)), 'query_create')
        for key in ('enable_content', 'enable_link', 'enable_classical', 'enable_sonic', 'enable_globalids', 'enable_xids', 'additional_credits'):
            checked(bind(music, 'gnsdk_musicid_query_option_set', [P, S, S])(query, ('gnsdk_musicid_option_' + key).encode(), b'1'), 'query_options')
        if request.get('action') == 'details':
            serialized = str(request.get('sdkData', ''))
            if not serialized or len(serialized) > 1024 * 1024:
                raise ValueError('Invalid selected album result.')
            selected = P()
            checked(bind(manager, 'gnsdk_manager_gdo_deserialize', [S, C.POINTER(P)])(serialized.encode('ascii'), C.byref(selected)), 'selected_album')
            try: checked(bind(music, 'gnsdk_musicid_query_set_gdo', [P, P])(query, selected), 'set_album')
            finally: bind(manager, 'gnsdk_manager_gdo_release', [P])(selected)
        else:
            for key, value in [('title', title), ('track_artist', artist), ('album', album)]:
                if value:
                    checked(bind(music, 'gnsdk_musicid_query_set_text', [P, S, S])(query, ('gnsdk_musicid_field_' + key).encode(), value.encode('utf-8')), 'set_text')
        # Album queries provide stable release candidates, artwork and matched track numbers.
        checked(bind(music, 'gnsdk_musicid_query_find_albums', [P, C.POINTER(P)])(query, C.byref(gdo)), 'query')
        checked(bind(manager, 'gnsdk_manager_gdo_render', [P, U, C.POINTER(S)])(gdo, 1, C.byref(rendered)), 'render')
        if not rendered or len(rendered.value) > 4 * 1024 * 1024:
            raise RuntimeError('Invalid Gracenote result size.')
        serialized_albums = {}
        count = U()
        checked(bind(manager, 'gnsdk_manager_gdo_child_count', [P, S, C.POINTER(U)])(gdo, b'gnsdk_ctx_album!', C.byref(count)), 'albums')
        for index in range(1, min(count.value, 40) + 1):
            child, serialized = P(), S()
            checked(bind(manager, 'gnsdk_manager_gdo_child_get', [P, S, U, C.POINTER(P)])(gdo, b'gnsdk_ctx_album!', index, C.byref(child)), 'album')
            try:
                checked(bind(manager, 'gnsdk_manager_gdo_serialize', [P, C.POINTER(S)])(child, C.byref(serialized)), 'serialize_album')
                serialized_albums[str(index)] = serialized.value.decode('ascii')
            finally:
                if serialized: bind(manager, 'gnsdk_manager_string_free', [S])(serialized)
                bind(manager, 'gnsdk_manager_gdo_release', [P])(child)
        return dict(sdkVersion=sdk_version, ready=True, candidates=parse_candidates(rendered.value, title, str(request.get('track', '')), serialized_albums))
    finally:
        if rendered: bind(manager, 'gnsdk_manager_string_free', [S])(rendered)
        if gdo: bind(manager, 'gnsdk_manager_gdo_release', [P])(gdo)
        if query: bind(music, 'gnsdk_musicid_query_release', [P])(query)
        if locale: bind(manager, 'gnsdk_manager_locale_release', [P])(locale)
        if user: bind(manager, 'gnsdk_manager_user_release', [P])(user)
        if initialized: bind(manager, 'gnsdk_manager_shutdown', [])()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sdk-dir', type=Path, required=True)
    p.add_argument('--config', type=Path, required=True)
    p.add_argument('--user', type=Path, required=True)
    p.add_argument('--request', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    if a.out.exists(): p.error('Output exists; choose a new filename.')
    result = lookup(a.sdk_dir.resolve(), a.config.resolve(), a.user.resolve(), json.loads(a.request.read_text(encoding='utf-8')))
    a.out.write_text(json.dumps(result, ensure_ascii=False), encoding='utf-8')
    print(json.dumps(dict(ready=result['ready'], candidates=len(result['candidates']))))


if __name__ == '__main__':
    try: main()
    except Exception as e:
        print(f'Error: {e}', file=sys.stderr)
        raise SystemExit(1)
