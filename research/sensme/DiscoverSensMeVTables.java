// @category NegiPlayer
import ghidra.app.script.GhidraScript;
import ghidra.program.model.mem.*;
import ghidra.program.model.address.*;

public class DiscoverSensMeVTables extends GhidraScript {
    public void run() throws Exception {
        int created = 0;
        for (MemoryBlock block : currentProgram.getMemory().getBlocks()) {
            if (!block.isInitialized() || block.isExecute()) continue;
            Address at = block.getStart();
            for (long offset=0; offset+4<=block.getSize(); offset+=4) {
                long pointer = Integer.toUnsignedLong(currentProgram.getMemory().getInt(at.add(offset)));
                Address target = toAddr(pointer);
                MemoryBlock code = currentProgram.getMemory().getBlock(target);
                if (code == null || !code.isExecute() || getFunctionContaining(target) != null) continue;
                int first = Byte.toUnsignedInt(currentProgram.getMemory().getByte(target));
                if (first!=0x55 && first!=0x56 && first!=0x53 && first!=0x51 && first!=0x8b && first!=0x83 && first!=0x81) continue;
                disassemble(target);
                if (createFunction(target, null) != null) { created++; println("Vtable candidate "+target); }
            }
        }
        println("Created "+created+" functions from data pointers");
    }
}
