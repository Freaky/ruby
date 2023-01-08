module RubyVM::MJIT
  class ExitCompiler
    def initialize
      # TODO: Use GC offsets
      @gc_refs = []
    end

    # Used for invalidating a block on entry.
    # @param pc [Integer]
    # @param asm [RubyVM::MJIT::Assembler]
    def compile_entry_exit(pc, asm, cause:)
      # Increment per-insn exit counter
      incr_insn_exit(pc, asm)

      # TODO: Saving pc and sp may be needed later

      # Restore callee-saved registers
      asm.comment("#{cause}: entry exit")
      asm.pop(SP)
      asm.pop(EC)
      asm.pop(CFP)

      asm.mov(:rax, Qundef)
      asm.ret
    end

    # @param ocb [CodeBlock]
    def compile_leave_exit(asm)
      # Restore callee-saved registers
      asm.pop(SP)
      asm.pop(EC)
      asm.pop(CFP)

      # :rax is written by #leave
      asm.ret
    end

    # @param jit [RubyVM::MJIT::JITState]
    # @param ctx [RubyVM::MJIT::Context]
    # @param asm [RubyVM::MJIT::Assembler]
    def compile_side_exit(jit, ctx, asm)
      # Increment per-insn exit counter
      incr_insn_exit(jit.pc, asm)

      # Fix pc/sp offsets for the interpreter
      save_pc_and_sp(jit, ctx.dup, asm) # dup to avoid sp_offset update

      # Restore callee-saved registers
      asm.comment("exit to interpreter on #{pc_to_insn(jit.pc).name}")
      asm.pop(SP)
      asm.pop(EC)
      asm.pop(CFP)

      asm.mov(:rax, Qundef)
      asm.ret
    end

    # @param ctx [RubyVM::MJIT::Context]
    # @param asm [RubyVM::MJIT::Assembler]
    # @param block_stub [RubyVM::MJIT::BlockStub]
    def compile_block_stub(ctx, asm, block_stub)
      # Call rb_mjit_block_stub_hit
      asm.comment("block stub hit: #{block_stub.iseq.body.location.label}@#{C.rb_iseq_path(block_stub.iseq)}:#{iseq_lineno(block_stub.iseq, block_stub.pc)}")
      asm.mov(:rdi, to_value(block_stub))
      asm.mov(:esi, ctx.sp_offset)
      asm.call(C.rb_mjit_block_stub_hit)

      # Jump to the address returned by rb_mjit_stub_hit
      asm.jmp(:rax)
    end

    # @param jit [RubyVM::MJIT::JITState]
    # @param ctx [RubyVM::MJIT::Context]
    # @param asm [RubyVM::MJIT::Assembler]
    # @param branch_stub [RubyVM::MJIT::BranchStub]
    # @param branch_target_p [TrueClass,FalseClass]
    def compile_branch_stub(jit, ctx, asm, branch_stub, branch_target_p)
      # Call rb_mjit_branch_stub_hit
      asm.comment("branch stub hit: #{branch_stub.iseq.body.location.label}@#{C.rb_iseq_path(branch_stub.iseq)}:#{iseq_lineno(branch_stub.iseq, branch_target_p ? branch_stub.branch_target_pc : branch_stub.fallthrough_pc)}")
      asm.mov(:rdi, to_value(branch_stub))
      asm.mov(:esi, ctx.sp_offset)
      asm.mov(:edx, branch_target_p ? 1 : 0)
      asm.call(C.rb_mjit_branch_stub_hit)

      # Jump to the address returned by rb_mjit_stub_hit
      asm.jmp(:rax)
    end

    private

    def pc_to_insn(pc)
      Compiler.decode_insn(C.VALUE.new(pc).*)
    end

    # @param pc [Integer]
    # @param asm [RubyVM::MJIT::Assembler]
    def incr_insn_exit(pc, asm)
      if C.mjit_opts.stats
        insn = Compiler.decode_insn(C.VALUE.new(pc).*)
        asm.comment("increment insn exit: #{insn.name}")
        asm.mov(:rax, (C.mjit_insn_exits + insn.bin).to_i)
        asm.add([:rax], 1) # TODO: lock
      end
    end

    # @param jit [RubyVM::MJIT::JITState]
    # @param ctx [RubyVM::MJIT::Context]
    # @param asm [RubyVM::MJIT::Assembler]
    def save_pc_and_sp(jit, ctx, asm)
      # Update pc (TODO: manage PC offset?)
      asm.comment("save PC#{' and SP' if ctx.sp_offset != 0} to CFP")
      asm.mov(:rax, jit.pc) # rax = jit.pc
      asm.mov([CFP, C.rb_control_frame_t.offsetof(:pc)], :rax) # cfp->pc = rax

      # Update sp
      if ctx.sp_offset != 0
        asm.add(SP, C.VALUE.size * ctx.sp_offset) # sp += stack_size
        asm.mov([CFP, C.rb_control_frame_t.offsetof(:sp)], SP) # cfp->sp = sp
        ctx.sp_offset = 0
      end
    end

    def to_value(obj)
      @gc_refs << obj
      C.to_value(obj)
    end

    def iseq_lineno(iseq, pc)
      C.rb_iseq_line_no(iseq, (pc - iseq.body.iseq_encoded.to_i) / C.VALUE.size)
    end
  end
end