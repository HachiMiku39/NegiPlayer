// Local interoperability research only; output is not a redistributable engine.
// @category NegiPlayer
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;

public class ExportSensMe extends GhidraScript {
    @Override public void run() throws Exception {
        Path out = Paths.get(getScriptArgs()[0]);
        Files.createDirectories(out.resolve("functions"));
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        try (PrintWriter index = new PrintWriter(Files.newBufferedWriter(out.resolve("functions.tsv"))); 
             PrintWriter refs = new PrintWriter(Files.newBufferedWriter(out.resolve("references.tsv")));
             PrintWriter strings = new PrintWriter(Files.newBufferedWriter(out.resolve("strings.tsv")))) {
            index.println("address\tname\tsize\tcallers\tcallees\tdecompiled");
            FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
            while (functions.hasNext() && !monitor.isCancelled()) {
                Function function = functions.next();
                String address = function.getEntryPoint().toString();
                List<String> callers = new ArrayList<>(), callees = new ArrayList<>();
                for (Function f : function.getCallingFunctions(monitor)) callers.add(f.getEntryPoint().toString());
                for (Function f : function.getCalledFunctions(monitor)) callees.add(f.getEntryPoint().toString());
                Collections.sort(callers); Collections.sort(callees);
                boolean complete = false;
                if (!function.isExternal() && !function.isThunk()) {
                    DecompileResults result = decompiler.decompileFunction(function, 30, monitor);
                    if (result.decompileCompleted() && result.getDecompiledFunction() != null) {
                        Files.writeString(out.resolve("functions").resolve(address+".c"), result.getDecompiledFunction().getC());
                        complete = true;
                    }
                }
                index.println(address+"\t"+function.getName()+"\t"+function.getBody().getNumAddresses()+"\t"+String.join(",",callers)+"\t"+String.join(",",callees)+"\t"+complete);
                for (Reference reference : getReferencesTo(function.getEntryPoint())) {
                    Function from = getFunctionContaining(reference.getFromAddress());
                    refs.println(address+"\t"+reference.getFromAddress()+"\t"+(from==null?"":from.getEntryPoint())+"\t"+reference.getReferenceType());
                }
            }
            DataIterator data = currentProgram.getListing().getDefinedData(true);
            while (data.hasNext()) {
                Data item = data.next();
                if (!item.hasStringValue()) continue;
                String value = String.valueOf(item.getValue()).replace("\n","\\n").replace("\t","\\t").replace("\r","\\r");
                for (Reference reference : getReferencesTo(item.getAddress())) {
                    Function from = getFunctionContaining(reference.getFromAddress());
                    strings.println(item.getAddress()+"\t"+(from==null?"":from.getEntryPoint())+"\t"+reference.getFromAddress()+"\t"+value);
                }
            }
        } finally { decompiler.dispose(); }
        println("Exported research to "+out);
    }
}
