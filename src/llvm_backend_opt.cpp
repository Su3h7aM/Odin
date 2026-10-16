/**************************************************************************

	IMPORTANT NOTE(bill, 2021-11-06): Regarding Optimization Passes

	A lot of the passes taken here have been modified with what was 
	partially done in LLVM 11. 

	Passes that CANNOT be used by Odin due to C-like optimizations which 
	are not compatible with Odin:
		
		LLVMAddCorrelatedValuePropagationPass 
		LLVMAddAggressiveInstCombinerPass
		LLVMAddInstructionCombiningPass
		LLVMAddIndVarSimplifyPass
		LLVMAddLoopUnrollPass
		LLVMAddEarlyCSEMemSSAPass
		LLVMAddGVNPass
		LLVMAddDeadStoreEliminationPass - Causes too many false positive
		
	Odin does not allow poison-value based optimizations. 
	
	For example, *-flowing integers in C is "undefined behaviour" and thus 
	many optimizers, including LLVM, take advantage of this for a certain 
	class of optimizations. Odin on the other hand defines *-flowing 
	behaviour to obey the rules of 2's complement, meaning wrapping is a 
	expected. This means any outputted IR containing the following flags 
	may cause incorrect behaviour:
	
		nsw (no signed wrap)
		nuw (no unsigned wrap)
		poison (poison value)
**************************************************************************/


// gb_internal LLVMBool lb_must_preserve_predicate_callback(LLVMValueRef value, void *user_data) {
// 	lbModule *m = cast(lbModule *)user_data;
// 	if (m == nullptr) {
// 		return false;
// 	}
// 	if (value == nullptr) {
// 		return false;
// 	}
// 	return LLVMIsAAllocaInst(value) != nullptr;
// }

/**************************************************************************
	IMPORTANT NOTE(bill, 2021-11-06): Custom Passes
	
	The procedures below are custom written passes to aid in the 
	optimization of Odin programs	
**************************************************************************/

gb_internal void lb_run_fast_float_math_pass(lbProcedure *p) {
#if LLVM_VERSION_MAJOR >= 18

	Entity *e = p->entity;
	if (e == nullptr) {
		return;
	}
	GB_ASSERT(e->kind == Entity_Procedure);


	u64 fast_math_flags = e->Procedure.fast_math_flags;
	LLVMFastMathFlags llvm_flags = 0;
	if (fast_math_flags & (1 << OdinFastMath_Allow_Reassoc))    llvm_flags |= LLVMFastMathAllowReassoc;
	if (fast_math_flags & (1 << OdinFastMath_No_NaNs))          llvm_flags |= LLVMFastMathNoNaNs;
	if (fast_math_flags & (1 << OdinFastMath_No_Infs))          llvm_flags |= LLVMFastMathNoInfs;
	if (fast_math_flags & (1 << OdinFastMath_No_Signed_Zeros))  llvm_flags |= LLVMFastMathNoSignedZeros;
	if (fast_math_flags & (1 << OdinFastMath_Allow_Reciprocal)) llvm_flags |= LLVMFastMathAllowReciprocal;
	if (fast_math_flags & (1 << OdinFastMath_Allow_Contract))   llvm_flags |= LLVMFastMathAllowContract;
	if (fast_math_flags & (1 << OdinFastMath_Approx_Func))      llvm_flags |= LLVMFastMathApproxFunc;

	if (llvm_flags == 0) {
		return;
	}

	for (LLVMBasicBlockRef block = LLVMGetFirstBasicBlock(p->value);
	     block != nullptr;
	     block = LLVMGetNextBasicBlock(block)) {
		for (LLVMValueRef instr = LLVMGetFirstInstruction(block);
		     instr != nullptr;
		     instr = LLVMGetNextInstruction(instr))  {			
			if (LLVMCanValueUseFastMathFlags(instr)) {
				LLVMSetFastMathFlags(instr, llvm_flags);
			}
		}
	}
#else
	// LLVMSetFastMathFlags doesn't seem to exist in LLVM 17,
	// so @(fast_math) becomes no op on older LLVM
	gb_unused(p);
#endif
}

gb_internal void lb_run_remove_dead_instruction_pass(lbProcedure *p) {
	isize removal_count = 0;
	isize pass_count = 0;
	isize const max_pass_count = 10;
	isize original_instruction_count = 0;
	// Custom remove dead instruction pass
	for (; pass_count < max_pass_count; pass_count++) {
		bool was_dead_instructions = false;

		// NOTE(bill): Iterate backwards
		// reduces the number of passes as things later on will depend on things previously
		for (LLVMBasicBlockRef block = LLVMGetLastBasicBlock(p->value);
		     block != nullptr;
		     block = LLVMGetPreviousBasicBlock(block)) {
			// NOTE(bill): Iterate backwards
			// reduces the number of passes as things later on will depend on things previously
			for (LLVMValueRef instr = LLVMGetLastInstruction(block);
			     instr != nullptr;
			     /**/)  {
			     	if (pass_count == 0) {
			     		original_instruction_count += 1;
			     	}

				LLVMValueRef curr_instr = instr;
				instr = LLVMGetPreviousInstruction(instr);

				LLVMUseRef first_use = LLVMGetFirstUse(curr_instr);
				if (first_use != nullptr)  {
					continue;
				}
				if (LLVMTypeOf(curr_instr) == nullptr) {
					continue;
				}

				// NOTE(bill): Explicit instructions are set here because some instructions could have side effects
				switch (LLVMGetInstructionOpcode(curr_instr)) {
				case LLVMAlloca:
					if (map_get(&p->tuple_fix_map, curr_instr) != nullptr) {
						// NOTE(bill, 2025-12-27): Remove temporary tuple fix alloca instructions
						// if they are never used
						removal_count += 1;
						LLVMInstructionEraseFromParent(curr_instr);
						was_dead_instructions = true;
					}
					break;
				case LLVMLoad:
					if (LLVMGetVolatile(curr_instr)) {
						break;
					}
					/*fallthrough*/
				case LLVMFNeg:
				case LLVMAdd:
				case LLVMFAdd:
				case LLVMSub:
				case LLVMFSub:
				case LLVMMul:
				case LLVMFMul:
				case LLVMUDiv:
				case LLVMSDiv:
				case LLVMFDiv:
				case LLVMURem:
				case LLVMSRem:
				case LLVMFRem:
				case LLVMShl:
				case LLVMLShr:
				case LLVMAShr:
				case LLVMAnd:
				case LLVMOr:
				case LLVMXor:
				case LLVMGetElementPtr:
				case LLVMTrunc:
				case LLVMZExt:
				case LLVMSExt:
				case LLVMFPToUI:
				case LLVMFPToSI:
				case LLVMUIToFP:
				case LLVMSIToFP:
				case LLVMFPTrunc:
				case LLVMFPExt:
				case LLVMPtrToInt:
				case LLVMIntToPtr:
				case LLVMBitCast:
				case LLVMAddrSpaceCast:
				case LLVMICmp:
				case LLVMFCmp:
				case LLVMSelect:
				case LLVMExtractElement:
				case LLVMShuffleVector:
				case LLVMExtractValue:
					removal_count += 1;
					LLVMInstructionEraseFromParent(curr_instr);
					was_dead_instructions = true;
					break;
				}
			}
		}

		if (!was_dead_instructions) {
			break;
		}
	}
}

gb_internal LLVMValueRef lb_run_instrumentation_pass_insert_call(lbProcedure *p, Entity *entity, LLVMBuilderRef dummy_builder, bool is_enter) {
	lbModule *m = p->module;

	if (p->debug_info != nullptr) {
		TokenPos pos = {};
		if (is_enter) {
			pos = ast_token(p->body).pos;
		} else {
			pos = ast_end_token(p->body).pos;
		}
		LLVMSetCurrentDebugLocation2(dummy_builder, lb_debug_location_from_token_pos(p, pos));
	}

	lbValue cc = lb_find_procedure_value_from_entity(m, entity);

	LLVMValueRef args[3] = {};
	args[0] = LLVMConstPointerCast(p->value, lb_type(m, t_rawptr));

	if (is_arch_wasm()) {
		args[1] = LLVMConstPointerNull(lb_type(m, t_rawptr));
	} else {
		LLVMValueRef returnaddress_args[1] = {};

		returnaddress_args[0] = LLVMConstInt(LLVMInt32TypeInContext(m->ctx), 0, false);

		char const *instrinsic_name = "llvm.returnaddress";
		unsigned id = LLVMLookupIntrinsicID(instrinsic_name, gb_strlen(instrinsic_name));
		GB_ASSERT_MSG(id != 0, "Unable to find %s", instrinsic_name);
		LLVMValueRef ip = LLVMGetIntrinsicDeclaration(m->mod, id, nullptr, 0);
		LLVMTypeRef call_type = LLVMIntrinsicGetType(m->ctx, id, nullptr, 0);
		args[1] = LLVMBuildCall2(dummy_builder, call_type, ip, returnaddress_args, gb_count_of(returnaddress_args), "");
	}

	Token name = {};
	if (p->entity) {
		name = p->entity->token;
	}
	args[2] = lb_emit_source_code_location_as_global_ptr(p, name.string, name.pos).value;

	LLVMTypeRef fnp = lb_type_internal_for_procedures_raw(p->module, entity->type);
	return LLVMBuildCall2(dummy_builder, fnp, cc.value, args, gb_count_of(args), "");
}


gb_internal void lb_run_instrumentation_pass(lbProcedure *p) {
	lbModule *m = p->module;
	Entity *enter = m->info->instrumentation_enter_entity;
	Entity *exit  = m->info->instrumentation_exit_entity;
	if (enter == nullptr || exit == nullptr) {
		return;
	}
	if (!(p->entity &&
	      p->entity->kind == Entity_Procedure &&
	      p->entity->Procedure.has_instrumentation)) {
		return;
	}

#define LLVM_V_NAME(x) x, cast(unsigned)(gb_count_of(x)-1)

	LLVMBuilderRef dummy_builder = LLVMCreateBuilderInContext(m->ctx);
	defer (LLVMDisposeBuilder(dummy_builder));

	LLVMBasicBlockRef entry_bb = p->entry_block->block;
	LLVMPositionBuilder(dummy_builder, entry_bb, LLVMGetFirstInstruction(entry_bb));
	lb_run_instrumentation_pass_insert_call(p, enter, dummy_builder, true);
	LLVMRemoveStringAttributeAtIndex(p->value, LLVMAttributeIndex_FunctionIndex, LLVM_V_NAME("instrument-function-entry"));

	unsigned bb_count = LLVMCountBasicBlocks(p->value);
	LLVMBasicBlockRef *bbs = gb_alloc_array(temporary_allocator(), LLVMBasicBlockRef, bb_count);
	LLVMGetBasicBlocks(p->value, bbs);
	for (unsigned i = 0; i < bb_count; i++) {
		LLVMBasicBlockRef bb = bbs[i];
		LLVMValueRef terminator = LLVMGetBasicBlockTerminator(bb);
		if (terminator == nullptr ||
		    !LLVMIsAReturnInst(terminator)) {
			continue;
		}

		// TODO(bill): getTerminatingMustTailCall()
		// If T is preceded by a musttail call, that's the real terminator.
		// if (CallInst *CI = BB.getTerminatingMustTailCall())
		// 	T = CI;


		LLVMPositionBuilderBefore(dummy_builder, terminator);
		lb_run_instrumentation_pass_insert_call(p, exit, dummy_builder, false);
	}

	LLVMRemoveStringAttributeAtIndex(p->value, LLVMAttributeIndex_FunctionIndex, LLVM_V_NAME("instrument-function-exit"));

#undef LLVM_V_NAME
}



gb_internal void lb_run_function_pass_manager(LLVMPassManagerRef fpm, lbProcedure *p, lbFunctionPassManagerKind pass_manager_kind) {
	if (p == nullptr) {
		return;
	}

	lb_run_fast_float_math_pass(p);

	// NOTE(bill): LLVMAddDCEPass doesn't seem to be exported in the official DLL's for LLVM
	// which means we cannot rely upon it
	// This is also useful for read the .ll for debug purposes because a lot of instructions
	// are not removed
	lb_run_remove_dead_instruction_pass(p);

	lb_run_instrumentation_pass(p);

	switch (pass_manager_kind) {
	case lbFunctionPassManager_none:
	    return;
	case lbFunctionPassManager_default:
	case lbFunctionPassManager_default_without_memcpy:
	    if (build_context.optimization_level < 0) {
	        return;
	    }
	    break;
	}

	LLVMRunFunctionPassManager(fpm, p->value);
}

gb_internal void llvm_delete_function(LLVMValueRef func) {
	// for (LLVMBasicBlockRef block = LLVMGetFirstBasicBlock(func); block != nullptr; /**/) {
	// 	LLVMBasicBlockRef curr_block = block;
	// 	block = LLVMGetNextBasicBlock(block);
	// 	for (LLVMValueRef instr = LLVMGetFirstInstruction(curr_block); instr != nullptr; /**/) {
	// 		LLVMValueRef curr_instr = instr;
	// 		instr = LLVMGetNextInstruction(instr);
			
	// 		LLVMInstructionEraseFromParent(curr_instr);
	// 	}
	// 	LLVMRemoveBasicBlockFromParent(curr_block);
	// }
	LLVMDeleteFunction(func);
}

// Helper to append a value to an llvm metadata array global (llvm.used or llvm.compiler.used)
gb_internal void lb_append_to_llvm_used_list(lbModule *m, LLVMValueRef value, char const *list_name) {
	LLVMValueRef global = LLVMGetNamedGlobal(m->mod, list_name);

	LLVMValueRef *constants;
	int operands = 1;

	if (global != NULL) {
		GB_ASSERT(LLVMIsAGlobalVariable(global));
		LLVMValueRef initializer = LLVMGetInitializer(global);

		GB_ASSERT(LLVMIsAConstantArray(initializer));
		operands = LLVMGetNumOperands(initializer) + 1;
		constants = gb_alloc_array(temporary_allocator(), LLVMValueRef, operands);

		for (int i = 0; i < operands - 1; i++) {
			LLVMValueRef operand = LLVMGetOperand(initializer, i);
			GB_ASSERT(LLVMIsAConstant(operand));
			constants[i] = operand;
		}

		LLVMDeleteGlobal(global);
	} else {
		constants = gb_alloc_array(temporary_allocator(), LLVMValueRef, 1);
	}

	LLVMTypeRef Int8PtrTy = LLVMPointerType(LLVMInt8TypeInContext(m->ctx), 0);
	LLVMTypeRef ATy = llvm_array_type(Int8PtrTy, operands);

	constants[operands - 1] = LLVMConstBitCast(value, Int8PtrTy);
	LLVMValueRef initializer = LLVMConstArray(Int8PtrTy, constants, operands);

	global = LLVMAddGlobal(m->mod, ATy, list_name);
	LLVMSetLinkage(global, LLVMAppendingLinkage);
	LLVMSetSection(global, "llvm.metadata");
	LLVMSetInitializer(global, initializer);
}

gb_internal void lb_append_to_compiler_used(lbModule *m, LLVMValueRef value) {
	lb_append_to_llvm_used_list(m, value, "llvm.compiler.used");
}

// llvm.used survives LTO linker optimizations (unlike llvm.compiler.used)
gb_internal void lb_append_to_used(lbModule *m, LLVMValueRef value) {
	lb_append_to_llvm_used_list(m, value, "llvm.used");
}

gb_internal void lb_run_remove_unused_function_pass(lbModule *m) {
	isize removal_count = 0;
	isize pass_count = 0;
	isize const max_pass_count = 10;

	// Custom remove dead function pass (for internal linkage functions)
	for (; pass_count < max_pass_count; pass_count++) {
		bool was_dead = false;
		for (LLVMValueRef func = LLVMGetFirstFunction(m->mod);
		     func != nullptr;
		     /**/
		     ) {
		     	LLVMValueRef curr_func = func;
		     	func = LLVMGetNextFunction(func);

			LLVMUseRef first_use = LLVMGetFirstUse(curr_func);
			if (first_use != nullptr)  {
				continue;
			}
			String name = {};
			name.text = cast(u8 *)LLVMGetValueName2(curr_func, cast(size_t *)&name.len);

			if (LLVMIsDeclaration(curr_func)) {
				// Ignore for the time being
				continue;
			}
			LLVMLinkage linkage = LLVMGetLinkage(curr_func);
			if (linkage != LLVMInternalLinkage) {
				continue;
			}

			Entity **found = map_get(&m->procedure_values, curr_func);
			if (found && *found) {
				Entity *e = *found;
				bool is_required = (e->flags & EntityFlag_Require) == EntityFlag_Require;
				if (is_required) {
					lb_append_to_compiler_used(m, curr_func);
					continue;
				}
			}

			llvm_delete_function(curr_func);
			was_dead = true;
			removal_count += 1;
		}
		if (!was_dead) {
			break;
		}
	}
}


gb_internal void lb_run_remove_unused_globals_pass(lbModule *m) {
	isize removal_count = 0;
	isize pass_count = 0;
	isize const max_pass_count = 10;
	// Custom remove dead function pass
	for (; pass_count < max_pass_count; pass_count++) {
		bool was_dead = false;	
		for (LLVMValueRef global = LLVMGetFirstGlobal(m->mod);
		     global != nullptr;
		     /**/
		     ) {
		     	LLVMValueRef curr_global = global;
		     	global = LLVMGetNextGlobal(global);
		     	
			LLVMUseRef first_use = LLVMGetFirstUse(curr_global);
			if (first_use != nullptr)  {
				continue;
			}
			String name = {};
			name.text = cast(u8 *)LLVMGetValueName2(curr_global, cast(size_t *)&name.len);
						
			LLVMLinkage linkage = LLVMGetLinkage(curr_global);
			if (linkage != LLVMInternalLinkage) {
				continue;
			}
			
			Entity **found = map_get(&m->procedure_values, curr_global);
			if (found && *found) {
				Entity *e = *found;
				bool is_required = (e->flags & EntityFlag_Require) == EntityFlag_Require;
				if (is_required) {
					continue;
				}
			}

			LLVMDeleteGlobal(curr_global);
			was_dead = true;
			removal_count += 1;
		}
		if (!was_dead) {
			break;
		}
	}
}

// NOTE(bill, 2026-10-03)
//
// LLVM's fast instruction selector cannot select a first class aggregate `load`, `store`, `insertvalue`, or `select`,
// and hands the rest of the block to SelectionDAG.
// SROA leaves many behind so it stores/loads the fields instead
enum {
	LB_SCALARIZE_MAX_LEAVES = 32,
	LB_SCALARIZE_MAX_DEPTH  = 8,
};

struct lbAggregateLeaf {
	unsigned path[LB_SCALARIZE_MAX_DEPTH];
	unsigned depth;
};

struct lbScalarizedPhi {
	LLVMValueRef aggregate;
	unsigned     path[LB_SCALARIZE_MAX_DEPTH];
	unsigned     depth;
	LLVMValueRef field;
	bool         ok;
};

struct lbFastIselLowering {
	lbModule *     m;
	LLVMBuilderRef builder;
	LLVMValueRef   store;
	Array<lbScalarizedPhi> phis;
};

gb_internal i64 lb_aggregate_path_offset(LLVMTypeRef type, unsigned const *path, unsigned depth, LLVMTypeRef *leaf_type_) {
	i64 offset = 0;
	for (unsigned d = 0; d < depth; d++) {
		if (LLVMGetTypeKind(type) == LLVMStructTypeKind) {
			bool is_packed = LLVMIsPackedStruct(type);
			i64 field_offset = 0;
			for (unsigned i = 0; i <= path[d]; i++) {
				LLVMTypeRef field = LLVMStructGetTypeAtIndex(type, i);
				if (!is_packed) {
					field_offset = llvm_align_formula(field_offset, lb_alignof(field));
				}
				if (i == path[d]) {
					type = field;
					break;
				}
				field_offset += lb_sizeof(field);
			}
			offset += field_offset;
		} else {
			type = OdinLLVMGetArrayElementType(type);
			offset += cast(i64)path[d] * lb_sizeof(type);
		}
	}
	if (leaf_type_) *leaf_type_ = type;
	return offset;
}

gb_internal bool lb_aggregate_leaves(LLVMTypeRef type, unsigned *path, unsigned depth, lbAggregateLeaf *leaves, isize *leaf_count) {
	LLVMTypeKind kind = LLVMGetTypeKind(type);
	if (kind == LLVMStructTypeKind || kind == LLVMArrayTypeKind) {
		if (depth >= LB_SCALARIZE_MAX_DEPTH) {
			return false;
		}
		if (kind == LLVMStructTypeKind && LLVMIsOpaqueStruct(type)) {
			return false;
		}
		unsigned count = kind == LLVMStructTypeKind ? LLVMCountStructElementTypes(type) : cast(unsigned)LLVMGetArrayLength(type);
		for (unsigned i = 0; i < count; i++) {
			path[depth] = i;
			LLVMTypeRef elem = kind == LLVMStructTypeKind ? LLVMStructGetTypeAtIndex(type, i) : OdinLLVMGetArrayElementType(type);
			if (!lb_aggregate_leaves(elem, path, depth+1, leaves, leaf_count)) {
				return false;
			}
		}
		return true;
	}

	if (*leaf_count >= LB_SCALARIZE_MAX_LEAVES) {
		return false;
	}

	lbAggregateLeaf *leaf = &leaves[(*leaf_count)++];
	gb_memmove(leaf->path, path, depth*gb_size_of(unsigned));
	leaf->depth = depth;
	return true;
}

gb_internal unsigned lb_aggregate_field_alignment(unsigned alignment, i64 offset) {
	unsigned a = gb_max(alignment, 1u);
	while (offset % a != 0) {
		a >>= 1;
	}
	return a;
}

gb_internal LLVMValueRef lb_aggregate_field_gep(lbModule *m, LLVMBuilderRef b, LLVMTypeRef type, LLVMValueRef ptr, unsigned const *path, unsigned depth) {
	LLVMValueRef indices[LB_SCALARIZE_MAX_DEPTH+1] = {};
	LLVMTypeRef i32 = LLVMInt32TypeInContext(m->ctx);
	indices[0] = LLVMConstInt(i32, 0, false);
	for (unsigned d = 0; d < depth; d++) {
		indices[d+1] = LLVMConstInt(i32, path[d], false);
	}
	return LLVMBuildInBoundsGEP2(b, type, ptr, indices, depth+1, "");
}

// returns false if the field cannot be reached without an aggregate value, and sets `*field_` to nullptr when it is undefined
gb_internal bool lb_aggregate_field_value(lbFastIselLowering *s, LLVMValueRef v, unsigned const *path, unsigned depth, LLVMValueRef *field_) {
	if (depth == 0) {
		*field_ = (LLVMIsUndef(v) || LLVMIsPoison(v)) ? nullptr : v;
		return true;
	}
	if (LLVMIsUndef(v) || LLVMIsPoison(v)) {
		*field_ = nullptr;
		return true;
	}

	if (LLVMIsAConstant(v)) {
		LLVMValueRef elem = LLVMGetAggregateElement(v, path[0]);
		if (elem != nullptr) {
			return lb_aggregate_field_value(s, elem, path+1, depth-1, field_);
		}
	} else if (LLVMIsAInsertValueInst(v)) {
		unsigned n = LLVMGetNumIndices(v);
		unsigned const *indices = LLVMGetIndices(v);

		unsigned k = 0;
		while (k < n && k < depth && indices[k] == path[k]) {
			k += 1;
		}

		if (k == n) {
			return lb_aggregate_field_value(s, LLVMGetOperand(v, 1), path+n, depth-n, field_);
		} else if (k < depth) {
			return lb_aggregate_field_value(s, LLVMGetOperand(v, 0), path, depth, field_);
		}
		return false;
	} else if (LLVMIsAExtractValueInst(v)) {
		unsigned n = LLVMGetNumIndices(v);
		if (n + depth <= LB_SCALARIZE_MAX_DEPTH) {
			unsigned full[LB_SCALARIZE_MAX_DEPTH];
			gb_memmove(full, LLVMGetIndices(v), n*gb_size_of(unsigned));
			gb_memmove(full+n, path, depth*gb_size_of(unsigned));
			return lb_aggregate_field_value(s, LLVMGetOperand(v, 0), full, n+depth, field_);
		}
		return false;
	} else if (LLVMIsASelectInst(v)) {
		LLVMValueRef x = nullptr;
		LLVMValueRef y = nullptr;
		if (!lb_aggregate_field_value(s, LLVMGetOperand(v, 1), path, depth, &x) ||
		    !lb_aggregate_field_value(s, LLVMGetOperand(v, 2), path, depth, &y)) {
			return false;
		}
		if (x == nullptr || y == nullptr) {
			*field_ = x ? x : y;
			return true;
		}
		LLVMPositionBuilderBefore(s->builder, s->store);
		LLVMSetCurrentDebugLocation2(s->builder, LLVMInstructionGetDebugLoc(s->store));
		*field_ = LLVMBuildSelect(s->builder, LLVMGetOperand(v, 0), x, y, "");
		return true;
	} else if (LLVMIsAPHINode(v)) {
		for (lbScalarizedPhi const &e : s->phis) {
			if (e.aggregate == v &&
			    e.depth == depth &&
			    gb_memcompare(e.path, path, depth*gb_size_of(unsigned)) == 0) {
				*field_ = e.field;
				return e.ok;
			}
		}

		LLVMTypeRef field_type = nullptr;
		lb_aggregate_path_offset(LLVMTypeOf(v), path, depth, &field_type);

		LLVMPositionBuilderBefore(s->builder, v);
		LLVMSetCurrentDebugLocation2(s->builder, nullptr);


		// NOTE(bill): cached before its incoming values, as a loop reaches it again
		isize index = s->phis.count;
		lbScalarizedPhi entry = {};
		entry.aggregate = v;
		gb_memmove(entry.path, path, depth*gb_size_of(unsigned));

		LLVMValueRef phi = LLVMBuildPhi(s->builder, field_type, "");
		entry.depth = depth;
		entry.field = phi;
		entry.ok    = true;
		array_add(&s->phis, entry);

		LLVMValueRef saved_store = s->store;
		bool ok = true;
		unsigned incoming_count = LLVMCountIncoming(v);
		for (unsigned k = 0; k < incoming_count; k++) {
			LLVMBasicBlockRef block = LLVMGetIncomingBlock(v, k);
			s->store = LLVMGetBasicBlockTerminator(block);
			LLVMValueRef field = nullptr;
			if (!lb_aggregate_field_value(s, LLVMGetIncomingValue(v, k), path, depth, &field)) {
				ok = false;
				field = nullptr;
			}
			if (field == nullptr) {
				field = LLVMGetUndef(field_type);
			}
			LLVMAddIncoming(phi, &field, &block, 1);
		}
		s->store = saved_store;
		s->phis[index].ok = ok;
		*field_ = phi;
		return ok;
	} else if (LLVMIsALoadInst(v) && !LLVMGetVolatile(v) && LLVMGetOrdering(v) == LLVMAtomicOrderingNotAtomic) {
		// NOTE(bill): Read the field where the aggregate was read, as the memory may change before the store
		LLVMTypeRef type       = LLVMTypeOf(v);
		LLVMTypeRef field_type = nullptr;
		i64 offset = lb_aggregate_path_offset(type, path, depth, &field_type);

		LLVMPositionBuilderBefore(s->builder, LLVMGetNextInstruction(v));
		LLVMSetCurrentDebugLocation2(s->builder, LLVMInstructionGetDebugLoc(v));

		LLVMValueRef ptr   = lb_aggregate_field_gep(s->m, s->builder, type, LLVMGetOperand(v, 0), path, depth);
		LLVMValueRef field = LLVMBuildLoad2(s->builder, field_type, ptr, "");
		LLVMSetAlignment(field, lb_aggregate_field_alignment(LLVMGetAlignment(v), offset));

		*field_ = field;
		return true;
	}

	if (depth == 1) {
		LLVMPositionBuilderBefore(s->builder, s->store);
		LLVMSetCurrentDebugLocation2(s->builder, LLVMInstructionGetDebugLoc(s->store));
		*field_ = LLVMBuildExtractValue(s->builder, v, path[0], "");
		return true;
	}
	return false;
}

gb_internal bool lb_scalarize_aggregate_store(lbFastIselLowering *s, LLVMValueRef store) {
	LLVMValueRef value = LLVMGetOperand(store, 0);
	LLVMValueRef ptr   = LLVMGetOperand(store, 1);
	LLVMTypeRef  type  = LLVMTypeOf(value);

	lbAggregateLeaf leaves[LB_SCALARIZE_MAX_LEAVES] = {};
	isize leaf_count = 0;
	unsigned path[LB_SCALARIZE_MAX_DEPTH] = {};

	if (!lb_aggregate_leaves(type, path, 0, leaves, &leaf_count)) {
		return false;
	}
	s->store = store;

	LLVMValueRef fields[LB_SCALARIZE_MAX_LEAVES] = {};
	for (isize i = 0; i < leaf_count; i++) {
		if (!lb_aggregate_field_value(s, value, leaves[i].path, leaves[i].depth, &fields[i])) {
			return false;
		}
	}

	unsigned alignment = LLVMGetAlignment(store);

	LLVMPositionBuilderBefore(s->builder, store);
	LLVMSetCurrentDebugLocation2(s->builder, LLVMInstructionGetDebugLoc(store));

	for (isize i = 0; i < leaf_count; i++) {
		if (fields[i] == nullptr) {
			continue;
		}
		i64 offset = lb_aggregate_path_offset(type, leaves[i].path, leaves[i].depth, nullptr);
		LLVMValueRef field_ptr = lb_aggregate_field_gep(s->m, s->builder, type, ptr, leaves[i].path, leaves[i].depth);
		LLVMValueRef field_store = LLVMBuildStore(s->builder, fields[i], field_ptr);
		LLVMSetAlignment(field_store, lb_aggregate_field_alignment(alignment, offset));
	}
	LLVMInstructionEraseFromParent(store);
	return true;
}

// NOTE(bill): If a a constant has too many fields to store one at a time is set or copied from a constant instead
gb_internal void lb_lower_large_constant_store(lbFastIselLowering *s, LLVMValueRef store) {
	lbModule *m = s->m;
	LLVMValueRef value = LLVMGetOperand(store, 0);
	LLVMValueRef ptr   = LLVMGetOperand(store, 1);
	LLVMTypeRef  type  = LLVMTypeOf(value);

	LLVMTargetDataRef data_layout = LLVMGetModuleDataLayout(m->mod);
	unsigned alignment = gb_max(LLVMGetAlignment(store), 1u);
	if (!LLVMIsAConstant(value) || lb_const_has_misaligned_pointer(data_layout, value, 0, alignment)) {
		return;
	}

	LLVMPositionBuilderBefore(s->builder, store);
	LLVMSetCurrentDebugLocation2(s->builder, LLVMInstructionGetDebugLoc(store));

	LLVMValueRef size = LLVMConstInt(LLVMInt64TypeInContext(m->ctx), LLVMStoreSizeOfType(data_layout, type), false);
	if (LLVMIsNull(value)) {
		LLVMBuildMemSet(s->builder, ptr, LLVMConstInt(LLVMInt8TypeInContext(m->ctx), 0, false), size, alignment);
		LLVMInstructionEraseFromParent(store);
		return;
	}

	LLVMValueRef global = LLVMAddGlobal(m->mod, type, "");
	LLVMSetInitializer(global, value);
	LLVMSetGlobalConstant(global, true);
	LLVMSetAlignment(global, alignment);

	LLVMSetLinkage(global, LLVMPrivateLinkage);
	LLVMSetUnnamedAddress(global, LLVMGlobalUnnamedAddr);

	LLVMBuildMemCpy(s->builder, ptr, alignment, global, alignment, size);

	LLVMInstructionEraseFromParent(store);
}

// NOTE(bill): The fast instruction selector in LLVM cannot select a call to `memmove` nor to the floating point `minnum` and `maxnum`.
// To improve things we can them through a function of the module which calls them
gb_internal void lb_redirect_unselectable_call(lbFastIselLowering *s, LLVMValueRef call) {
	lbModule *m = s->m;

	LLVMValueRef callee = LLVMGetCalledValue(call);
	if (!LLVMIsAFunction(callee)) {
		return;
	}
	size_t      name_len = 0;
	char const *name_text = LLVMGetValueName2(callee, &name_len);
	String      name = make_string(cast(u8 const *)name_text, name_len);

	LLVMTypeRef fn_type = LLVMGlobalGetValueType(callee);
	if (LLVMGetCalledFunctionType(call) != fn_type || LLVMIsFunctionVarArg(fn_type)) {
		return;
	}
	unsigned     param_count = LLVMCountParamTypes(fn_type);
	LLVMTypeKind return_kind = LLVMGetTypeKind(LLVMGetReturnType(fn_type));
	bool is_memmove = name == "memmove" && param_count == 3 && return_kind == LLVMPointerTypeKind;
	bool is_minmax  = (string_starts_with(name, str_lit("llvm.minnum.")) ||
	                   string_starts_with(name, str_lit("llvm.maxnum."))) &&
	                  (return_kind == LLVMFloatTypeKind ||
	                   return_kind == LLVMDoubleTypeKind);
	if (!is_memmove && !is_minmax) {
		return;
	}

	gbString wrapper_name = gb_string_make(heap_allocator(), "__$fast_isel$");
	wrapper_name          = gb_string_append_length(wrapper_name, name.text, name.len);
	defer (gb_string_free(wrapper_name));

	LLVMValueRef wrapper = LLVMGetNamedFunction(m->mod, wrapper_name);
	defer (LLVMSetOperand(call, cast(unsigned)LLVMGetNumOperands(call) - 1, wrapper));

	if (wrapper != nullptr) {
		return;
	}

	LLVMCallConv cc = cast(LLVMCallConv)LLVMGetFunctionCallConv(callee);
	wrapper = LLVMAddFunction(m->mod, wrapper_name, fn_type);
	LLVMSetLinkage(wrapper, LLVMInternalLinkage);
	LLVMSetFunctionCallConv(wrapper, cc);
	lb_add_attribute_to_proc(m, wrapper, "nounwind");

	LLVMValueRef params[3] = {};
	LLVMGetParams(wrapper, params);

	LLVMPositionBuilderAtEnd(s->builder, LLVMAppendBasicBlockInContext(m->ctx, wrapper, ""));
	LLVMSetCurrentDebugLocation2(s->builder, nullptr);

	LLVMValueRef inner = LLVMBuildCall2(s->builder, fn_type, callee, params, param_count, "");
	LLVMSetInstructionCallConv(inner, cc);
	if (is_memmove && lb_native_memory_lowering_enabled()) {
		LLVMAddCallSiteAttribute(inner, LLVMAttributeFunctionIndex, lb_create_enum_attribute(m->ctx, "nobuiltin", 0));
	}
	LLVMBuildRet(s->builder, inner);
}

gb_internal bool lb_is_aggregate_type(LLVMTypeRef type) {
	LLVMTypeKind kind = LLVMGetTypeKind(type);
	return kind == LLVMStructTypeKind || kind == LLVMArrayTypeKind;
}

gb_internal bool lb_is_plain_access(LLVMValueRef inst) {
	return !LLVMGetVolatile(inst) && LLVMGetOrdering(inst) == LLVMAtomicOrderingNotAtomic;
}

gb_internal void lb_lower_large_loaded_store(lbFastIselLowering *s, LLVMValueRef store) {
	lbModule *m = s->m;
	LLVMValueRef load = LLVMGetOperand(store, 0);
	LLVMValueRef ptr  = LLVMGetOperand(store, 1);
	LLVMUseRef   use  = LLVMGetFirstUse(load);
	if (!lb_is_plain_access(load) || LLVMGetNextUse(use) != nullptr) {
		return;
	}

	LLVMTypeRef type = LLVMTypeOf(load);
	LLVMTargetDataRef data_layout = LLVMGetModuleDataLayout(m->mod);
	LLVMValueRef size = LLVMConstInt(LLVMInt64TypeInContext(m->ctx), LLVMStoreSizeOfType(data_layout, type), false);

	unsigned load_alignment  = gb_max(LLVMGetAlignment(load), 1u);
	unsigned store_alignment = gb_max(LLVMGetAlignment(store), 1u);
	unsigned temp_alignment  = gb_max(LLVMABIAlignmentOfType(data_layout, type), load_alignment);

	LLVMValueRef fn = LLVMGetBasicBlockParent(LLVMGetInstructionParent(store));
	LLVMPositionBuilderBefore(s->builder, LLVMGetFirstInstruction(LLVMGetEntryBasicBlock(fn)));
	LLVMSetCurrentDebugLocation2(s->builder, nullptr);

	LLVMValueRef temp = LLVMBuildAlloca(s->builder, type, "");
	LLVMSetAlignment(temp, temp_alignment);

	LLVMPositionBuilderBefore(s->builder, LLVMGetNextInstruction(load));
	LLVMSetCurrentDebugLocation2(s->builder, LLVMInstructionGetDebugLoc(load));
	LLVMBuildMemCpy(s->builder, temp, temp_alignment, LLVMGetOperand(load, 0), load_alignment, size);

	LLVMPositionBuilderBefore(s->builder, store);
	LLVMSetCurrentDebugLocation2(s->builder, LLVMInstructionGetDebugLoc(store));
	LLVMBuildMemCpy(s->builder, ptr, store_alignment, temp, temp_alignment, size);

	LLVMInstructionEraseFromParent(store);
	LLVMInstructionEraseFromParent(load);
}

gb_internal void lb_lower_bool_select(lbFastIselLowering *s, LLVMValueRef select) {
	LLVMValueRef c = LLVMGetOperand(select, 0);
	LLVMValueRef x = LLVMGetOperand(select, 1);
	LLVMValueRef y = LLVMGetOperand(select, 2);
	if (LLVMGetTypeKind(LLVMTypeOf(c)) != LLVMIntegerTypeKind) {
		return;
	}
	LLVMPositionBuilderBefore(s->builder, select);
	LLVMSetCurrentDebugLocation2(s->builder, LLVMInstructionGetDebugLoc(select));
	LLVMValueRef t = LLVMConstInt(LLVMTypeOf(c), 1, false);

	LLVMValueRef res = nullptr;
	if (LLVMIsAConstantInt(x)) {
		res = LLVMConstIntGetZExtValue(x) ? LLVMBuildOr(s->builder, c, y, "") : LLVMBuildAnd(s->builder, LLVMBuildXor(s->builder, c, t, ""), y, "");
	} else if (LLVMIsAConstantInt(y)) {
		res = LLVMConstIntGetZExtValue(y) ? LLVMBuildOr(s->builder, LLVMBuildXor(s->builder, c, t, ""), x, "") : LLVMBuildAnd(s->builder, c, x, "");
	} else {
		LLVMValueRef a = LLVMBuildAnd(s->builder, c, x, "");
		LLVMValueRef b = LLVMBuildAnd(s->builder, LLVMBuildXor(s->builder, c, t, ""), y, "");
		res = LLVMBuildOr(s->builder, a, b, "");
	}
	LLVMReplaceAllUsesWith(select, res);
	LLVMInstructionEraseFromParent(select);
}

gb_internal void lb_truncate_bool_arguments(lbFastIselLowering *s, LLVMValueRef call) {
	LLVMTypeRef i1 = LLVMInt1TypeInContext(s->m->ctx);
	LLVMTypeRef i8 = LLVMInt8TypeInContext(s->m->ctx);
	LLVMBasicBlockRef block = LLVMGetInstructionParent(call);
	unsigned arg_count = LLVMGetNumArgOperands(call);
	for (unsigned a = 0; a < arg_count; a++) {
		LLVMValueRef arg = LLVMGetOperand(call, a);
		if (LLVMTypeOf(arg) != i1 || LLVMIsAConstantInt(arg)) {
			continue;
		}
		LLVMUseRef first_use = LLVMGetFirstUse(arg);
		if (LLVMIsATruncInst(arg) && LLVMGetInstructionParent(arg) == block &&
		    first_use != nullptr && LLVMGetNextUse(first_use) == nullptr) {
			continue;
		}
		LLVMPositionBuilderBefore(s->builder, call);
		LLVMSetCurrentDebugLocation2(s->builder, LLVMInstructionGetDebugLoc(call));
		LLVMValueRef byte = LLVMBuildZExt(s->builder, arg, i8, "");
		LLVMSetOperand(call, a, LLVMBuildTrunc(s->builder, byte, i1, ""));
	}
}

gb_internal void lb_lower_small_switch(lbFastIselLowering *s, LLVMValueRef sw) {
	enum {MAX_CASES = 3};
	LLVMValueRef cond = LLVMGetOperand(sw, 0);
	unsigned case_count = LLVMGetNumSuccessors(sw) - 1;
	if (case_count == 0 || case_count > MAX_CASES || LLVMGetIntTypeWidth(LLVMTypeOf(cond)) > 64) {
		return;
	}

	LLVMBasicBlockRef block      = LLVMGetInstructionParent(sw);
	LLVMBasicBlockRef next_block = LLVMGetNextBasicBlock(block);

	LLVMValueRef fn     = LLVMGetBasicBlockParent(block);
	LLVMMetadataRef loc = LLVMInstructionGetDebugLoc(sw);

	LLVMBasicBlockRef from[MAX_CASES+1] = {};
	LLVMBasicBlockRef to  [MAX_CASES+1] = {};

	LLVMBasicBlockRef curr = block;

	LLVMPositionBuilderBefore(s->builder, sw);
	LLVMSetCurrentDebugLocation2(s->builder, loc);

	for (unsigned j = 0; j < case_count; j++) {
		LLVMBasicBlockRef dest = LLVMGetSuccessor(sw, j+1);
		LLVMBasicBlockRef else_block = LLVMGetSwitchDefaultDest(sw);
		if (j+1 < case_count) {
			if (next_block != nullptr) {
				else_block = LLVMInsertBasicBlockInContext(s->m->ctx, next_block, "");
			} else {
				else_block = LLVMAppendBasicBlockInContext(s->m->ctx, fn, "");
			}
		}

#if LLVM_VERSION_MAJOR >= 22
		// LLVM 22 keeps a switch's case values apart from its operands
		LLVMValueRef case_value = LLVMGetSwitchCaseValue(sw, j+1);
#else
		LLVMValueRef case_value = LLVMGetOperand(sw, 2 + 2*j);
#endif
		LLVMValueRef cmp = LLVMBuildICmp(s->builder, LLVMIntEQ, cond, case_value, "");
		LLVMBuildCondBr(s->builder, cmp, dest, else_block);

		from[j] = curr;
		to[j]   = dest;

		if (j+1 < case_count) {
			curr = else_block;
			LLVMPositionBuilderAtEnd(s->builder, curr);
			LLVMSetCurrentDebugLocation2(s->builder, loc);
		}
	}
	from[case_count] = curr;
	to  [case_count] = LLVMGetSwitchDefaultDest(sw);
	LLVMInstructionEraseFromParent(sw);

	// the incoming entries for `block` become one for each new edge
	for (unsigned e = 0; e <= case_count; e++) {
		bool seen = false;
		for (unsigned k = 0; k < e; k++) {
			seen |= to[k] == to[e];
		}
		if (seen) {
			continue;
		}

		LLVMBasicBlockRef dest = to[e];
		for (LLVMValueRef phi = LLVMGetFirstInstruction(dest); phi != nullptr && LLVMIsAPHINode(phi); /**/) {
			LLVMValueRef next             = LLVMGetNextInstruction(phi);
			LLVMValueRef value_from_block = nullptr;

			unsigned incoming_count = LLVMCountIncoming(phi);
			for (unsigned k = 0; k < incoming_count; k++) {
				if (LLVMGetIncomingBlock(phi, k) == block) {
					value_from_block = LLVMGetIncomingValue(phi, k);
				}
			}

			if (value_from_block != nullptr) {
				LLVMPositionBuilderBefore(s->builder, phi);
				LLVMSetCurrentDebugLocation2(s->builder, nullptr);

				LLVMValueRef new_phi = LLVMBuildPhi(s->builder, LLVMTypeOf(phi), "");
				for (unsigned k = 0; k < incoming_count; k++) {
					LLVMBasicBlockRef incoming_block = LLVMGetIncomingBlock(phi, k);
					if (incoming_block != block) {
						LLVMValueRef incoming_value = LLVMGetIncomingValue(phi, k);
						LLVMAddIncoming(new_phi, &incoming_value, &incoming_block, 1);
					}
				}
				for (unsigned k = 0; k <= case_count; k++) {
					if (to[k] == dest) {
						LLVMAddIncoming(new_phi, &value_from_block, &from[k], 1);
					}
				}
				LLVMReplaceAllUsesWith(phi, new_phi);
				LLVMInstructionEraseFromParent(phi);
			}

			phi = next;
		}
	}
}

gb_internal bool lb_native_memory_target(void) {
	return build_context.metrics.os == TargetOs_linux && build_context.metrics.arch == TargetArch_amd64;
}

// Calls a native provider must never make. Checked in every mode, since the sweep does not run under LTO or sanitizers.
gb_internal bool lb_native_memory_is_libc_memop(LLVMValueRef callee) {
	String name = {};
	name.text = cast(u8 *)LLVMGetValueName2(callee, cast(size_t *)&name.len);
	String const names[] = {
		str_lit("memcpy"), str_lit("memmove"), str_lit("memset"),
		str_lit("__asan_memcpy"), str_lit("__asan_memmove"), str_lit("__asan_memset"),
		str_lit("__msan_memcpy"), str_lit("__msan_memmove"), str_lit("__msan_memset"),
		str_lit("__tsan_memcpy"), str_lit("__tsan_memmove"), str_lit("__tsan_memset"),
	};
	for (String const &s : names) {
		if (str_eq(name, s)) {
			return true;
		}
	}
	return false;
}

gb_internal bool lb_native_memory_provider_tagged(LLVMValueRef fn) {
	char const *key = "odin-native-memory-provider";
	LLVMAttributeRef attr = LLVMGetStringAttributeAtIndex(fn, LLVMAttributeIndex_FunctionIndex, key, cast(unsigned)gb_strlen(key));
	return attr != nullptr && LLVMIsStringAttribute(attr);
}

// Runs before LLVMRunPasses in every module. Providers are found by runtime entity identity, without creating or enqueuing procedures.
// Gated only on target, not on LTO or sanitizers: the provider bodies are optimized in every such build, so they always need the no-builtin tags.
// Every native provider and kernel, by runtime procedure name. Identity is the resolved runtime Entity, never a name prefix.
gb_internal char const *const lb_native_memory_provider_names[] = {
	"native_memcpy", "native_memmove", "native_memset", "native_memset_small",
	"native_memmove_volatile", "native_memset_volatile",
	"native_memcpy_sse2", "native_memcpy_avx2",
	"native_memmove_sse2", "native_memmove_avx2",
	"native_memset_sse2", "native_memset_avx2",
	"native_memset_volatile_sse2", "native_memset_volatile_avx2",
	"volatile_copy_forward", "volatile_copy_backward",
};

// True when e is one of the native provider entities. Does not create or enqueue procedures.
gb_internal bool lb_native_memory_is_provider_entity(lbModule *m, Entity *e) {
	if (e == nullptr || !lb_native_memory_target()) {
		return false;
	}
	AstPackage *pkg = m->info->runtime_package;
	for (char const *name : lb_native_memory_provider_names) {
		if (e == scope_lookup_current(pkg->scope, string_interner_insert(make_string_c(name)))) {
			return true;
		}
	}
	return false;
}

gb_internal void lb_configure_native_memory_providers(lbModule *m) {
	if (!lb_native_memory_target()) {
		return;
	}

	Entity *entities[gb_count_of(lb_native_memory_provider_names)] = {};
	AstPackage *pkg = m->info->runtime_package;
	for (usize i = 0; i < gb_count_of(lb_native_memory_provider_names); i++) {
		entities[i] = scope_lookup_current(pkg->scope, string_interner_insert(make_string_c(lb_native_memory_provider_names[i])));
		GB_ASSERT_MSG(entities[i] != nullptr, "Native memory provider not found: %s", lb_native_memory_provider_names[i]);
	}

	for (LLVMValueRef fn = LLVMGetFirstFunction(m->mod); fn != nullptr; fn = LLVMGetNextFunction(fn)) {
		Entity **found = map_get(&m->procedure_values, fn);
		if (found == nullptr || *found == nullptr || LLVMIsDeclaration(fn)) {
			continue;
		}
		bool is_provider = false;
		for (Entity *e : entities) {
			is_provider |= e == *found;
		}
		if (!is_provider) {
			continue;
		}
		LLVMAddAttributeAtIndex(fn, LLVMAttributeIndex_FunctionIndex, lb_create_string_attribute(m->ctx, str_lit("odin-native-memory-provider"), str_lit("")));
		LLVMAddAttributeAtIndex(fn, LLVMAttributeIndex_FunctionIndex, lb_create_string_attribute(m->ctx, str_lit("no-builtin-memcpy"), str_lit("")));
		LLVMAddAttributeAtIndex(fn, LLVMAttributeIndex_FunctionIndex, lb_create_string_attribute(m->ctx, str_lit("no-builtin-memmove"), str_lit("")));
		LLVMAddAttributeAtIndex(fn, LLVMAttributeIndex_FunctionIndex, lb_create_string_attribute(m->ctx, str_lit("no-builtin-memset"), str_lit("")));
	}
}

gb_internal bool lb_lower_native_memory(lbModule *m) {
	if (!lb_native_memory_target()) {
		return true;
	}
	// Without the sweep, provider bodies are only checked, never rewritten.
	bool lower = lb_native_memory_lowering_enabled();

	enum {Copy, Move, Fill, VolatileMove, VolatileFill, SmallFill, ProviderCount};
	char const *names[ProviderCount] = {
		"native_memcpy", "native_memmove", "native_memset",
		"native_memmove_volatile", "native_memset_volatile", "native_memset_small",
	};
	LLVMValueRef providers[ProviderCount] = {};
	if (lower) {
		for (unsigned i = 0; i < ProviderCount; i++) {
			providers[i] = lb_lookup_runtime_procedure(m, make_string_c(names[i])).value;
		}
	}

	unsigned copy_id = LLVMLookupIntrinsicID("llvm.memcpy", gb_strlen("llvm.memcpy"));
	unsigned move_id = LLVMLookupIntrinsicID("llvm.memmove", gb_strlen("llvm.memmove"));
	unsigned fill_id = LLVMLookupIntrinsicID("llvm.memset", gb_strlen("llvm.memset"));
	unsigned inline_copy_id = LLVMLookupIntrinsicID("llvm.memcpy.inline", gb_strlen("llvm.memcpy.inline"));
	unsigned inline_move_id = LLVMLookupIntrinsicID("llvm.memmove.inline", gb_strlen("llvm.memmove.inline"));
	unsigned inline_fill_id = LLVMLookupIntrinsicID("llvm.memset.inline", gb_strlen("llvm.memset.inline"));
	unsigned align_id = LLVMGetEnumAttributeKindForName("align", gb_strlen("align"));

	LLVMBuilderRef builder = LLVMCreateBuilderInContext(m->ctx);
	defer (LLVMDisposeBuilder(builder));
	auto work = array_make<LLVMValueRef>(heap_allocator(), 0, 32);
	defer (array_free(&work));

	for (LLVMValueRef fn = LLVMGetFirstFunction(m->mod); fn != nullptr; fn = LLVMGetNextFunction(fn)) {
		bool provider_body = lb_native_memory_provider_tagged(fn);
		for (LLVMValueRef provider : providers) {
			provider_body |= provider == fn;
		}
		if (!lower && !provider_body) {
			continue;
		}
		bool provider_violation = false;
		array_clear(&work);
		for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(fn); bb != nullptr; bb = LLVMGetNextBasicBlock(bb)) {
			for (LLVMValueRef inst = LLVMGetFirstInstruction(bb); inst != nullptr; inst = LLVMGetNextInstruction(inst)) {
				if (!LLVMIsACallInst(inst)) {
					continue;
				}
				LLVMValueRef callee = LLVMGetCalledValue(inst);
				if (!LLVMIsAFunction(callee)) {
					continue;
				}
				unsigned id = LLVMGetIntrinsicID(callee);
				if (id != 0 && (id == copy_id || id == move_id || id == fill_id)) {
					array_add(&work, inst);
				} else if (provider_body && lb_native_memory_is_libc_memop(callee)) {
					provider_violation = true;
				}
			}
		}
		if (!lower) {
			// Nothing is rewritten without the sweep, so any surviving memory intrinsic is a violation.
			provider_violation |= work.count != 0;
			array_clear(&work);
		}

		for (LLVMValueRef inst : work) {
			unsigned id = LLVMGetIntrinsicID(LLVMGetCalledValue(inst));
			bool fill = id == fill_id;
			LLVMValueRef dst = LLVMGetOperand(inst, 0);
			LLVMValueRef src_or_byte = LLVMGetOperand(inst, 1);
			LLVMValueRef len = LLVMGetOperand(inst, 2);
			LLVMValueRef volatile_arg = LLVMGetOperand(inst, 3);
			bool is_volatile = LLVMConstIntGetZExtValue(volatile_arg) != 0;
			if (LLVMGetPointerAddressSpace(LLVMTypeOf(dst)) != 0 ||
			    (!fill && LLVMGetPointerAddressSpace(LLVMTypeOf(src_or_byte)) != 0)) {
				gb_printf_err("Native Linux x64 memory lowering requires address space zero\n");
				return false;
			}

			unsigned dst_align = 1, src_align = 1;
			if (LLVMAttributeRef attr = LLVMGetCallSiteEnumAttribute(inst, 1, align_id)) {
				dst_align = cast(unsigned)LLVMGetEnumAttributeValue(attr);
			}
			if (!fill) {
				if (LLVMAttributeRef attr = LLVMGetCallSiteEnumAttribute(inst, 2, align_id)) {
					src_align = cast(unsigned)LLVMGetEnumAttributeValue(attr);
				}
			}
			LLVMPositionBuilderBefore(builder, inst);
			LLVMSetCurrentDebugLocation2(builder, LLVMInstructionGetDebugLoc(inst));
			u64 size = LLVMIsAConstantInt(len) ? LLVMConstIntGetZExtValue(len) : UINT64_MAX;
			if (size == 0) {
				LLVMInstructionEraseFromParent(inst);
				continue;
			}

			if (!is_volatile && size <= 16) {
				if (fill) {
					for (u64 offset = 0; offset < size; /**/) {
						u64 chunk = 8;
						while (chunk > size-offset) {
							chunk >>= 1;
						}
						LLVMTypeRef type = LLVMIntTypeInContext(m->ctx, cast(unsigned)(8*chunk));
						u64 repeated_byte = 0;
						for (u64 i = 0; i < chunk; i++) {
							repeated_byte |= cast(u64)1 << (8*i);
						}
						LLVMValueRef byte = LLVMBuildIntCast2(builder, src_or_byte, type, false, "");
						LLVMValueRef value = LLVMBuildMul(builder, byte, LLVMConstInt(type, repeated_byte, false), "");
						LLVMValueRef index = LLVMConstInt(lb_type(m, t_int), offset, false);
						LLVMValueRef ptr = LLVMBuildGEP2(builder, LLVMInt8TypeInContext(m->ctx), dst, &index, 1, "");
						LLVMValueRef store = LLVMBuildStore(builder, value, ptr);
						LLVMSetAlignment(store, lb_alignment_at_offset(dst_align, offset, chunk));
						offset += chunk;
					}
				} else {
					// Read the whole value before writing, including overlapping moves.
					LLVMTypeRef type = LLVMIntTypeInContext(m->ctx, cast(unsigned)(8*size));
					LLVMValueRef value = LLVMBuildLoad2(builder, type, src_or_byte, "");
					LLVMSetAlignment(value, src_align);
					LLVMValueRef store = LLVMBuildStore(builder, value, dst);
					LLVMSetAlignment(store, dst_align);
				}
				LLVMInstructionEraseFromParent(inst);
				continue;
			}

			// Provider bodies may expand constant operations up to 128 bytes. Other bodies keep the 64-byte copy limit.
			u64 inline_limit = provider_body ? 128 : 64;
			// llvm.memmove.inline does not exist in LLVM, so a move never takes the inline branch. Outside provider bodies it becomes a provider call; inside them it is reported as a violation.
			unsigned inline_id = fill ? inline_fill_id : id == copy_id ? inline_copy_id : inline_move_id;
			if (!is_volatile && size <= inline_limit && (!fill || provider_body) && inline_id != 0) {
				LLVMValueRef call = nullptr;
				if (fill) {
					LLVMTypeRef types[2] = {LLVMTypeOf(dst), LLVMTypeOf(len)};
					LLVMValueRef callee = LLVMGetIntrinsicDeclaration(m->mod, inline_fill_id, types, 2);
					LLVMValueRef args[4] = {dst, src_or_byte, len, volatile_arg};
					call = LLVMBuildCall2(builder, LLVMIntrinsicGetType(m->ctx, inline_fill_id, types, 2), callee, args, 4, "");
				} else {
					LLVMTypeRef types[3] = {LLVMTypeOf(dst), LLVMTypeOf(src_or_byte), LLVMTypeOf(len)};
					LLVMValueRef callee = LLVMGetIntrinsicDeclaration(m->mod, inline_id, types, 3);
					LLVMValueRef args[4] = {dst, src_or_byte, len, volatile_arg};
					call = LLVMBuildCall2(builder, LLVMIntrinsicGetType(m->ctx, inline_id, types, 3), callee, args, 4, "");
				}
				for (unsigned index = 1; index <= 2; index++) {
					if (LLVMAttributeRef attr = LLVMGetCallSiteEnumAttribute(inst, index, align_id)) {
						LLVMAddCallSiteAttribute(call, index, attr);
					}
				}
				LLVMInstructionEraseFromParent(inst);
				continue;
			}

			// Never introduce a recursive provider call from a kernel body.
			if (provider_body) {
				provider_violation = true;
				break;
			}
			unsigned provider_index = fill ? (is_volatile ? VolatileFill : Fill) :
			                          is_volatile ? VolatileMove : id == copy_id ? Copy : Move;
			LLVMValueRef callee = providers[provider_index];
			LLVMValueRef args[3] = {
				LLVMBuildPointerCast(builder, dst, lb_type(m, t_rawptr), ""),
				fill ? LLVMBuildIntCast2(builder, src_or_byte, LLVMInt8TypeInContext(m->ctx), false, "") :
				       LLVMBuildPointerCast(builder, src_or_byte, lb_type(m, t_rawptr), ""),
				LLVMBuildIntCast2(builder, len, lb_type(m, t_int), false, ""),
			};
			LLVMValueRef call = LLVMBuildCall2(builder, LLVMGlobalGetValueType(callee), callee, args, 3, "");
			LLVMSetInstructionCallConv(call, LLVMGetFunctionCallConv(callee));
			LLVMInstructionEraseFromParent(inst);
		}
		if (provider_violation) {
			gb_printf_err("Native Linux x64 memory provider contains a non-inline memory operation\n");
			return false;
		}
	}
	return true;
}

gb_internal void lb_lower_for_fast_isel(lbModule *m) {
	lbFastIselLowering s = {};
	s.m = m;

	s.builder = LLVMCreateBuilderInContext(m->ctx);
	defer (LLVMDisposeBuilder(s.builder));

	array_init(&s.phis, heap_allocator());
	defer (array_free(&s.phis));

	auto work = array_make<LLVMValueRef>(heap_allocator(), 0, 64);
	defer (array_free(&work));

	LLVMValueRef last_fn = LLVMGetLastFunction(m->mod);
	for (LLVMValueRef fn = LLVMGetFirstFunction(m->mod); fn != nullptr; fn = fn == last_fn ? nullptr : LLVMGetNextFunction(fn)) {
		array_clear(&work);
		array_clear(&s.phis);

		for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(fn); bb != nullptr; bb = LLVMGetNextBasicBlock(bb)) {
			for (LLVMValueRef i = LLVMGetFirstInstruction(bb); i != nullptr; i = LLVMGetNextInstruction(i)) {
				if (LLVMIsAStoreInst(i) && lb_is_plain_access(i) && lb_is_aggregate_type(LLVMTypeOf(LLVMGetOperand(i, 0)))) {
					array_add(&work, i);
				}
			}
		}
		for (LLVMValueRef store : work) {
			if (lb_scalarize_aggregate_store(&s, store)) {
				continue;
			}
			if (LLVMIsALoadInst(LLVMGetOperand(store, 0))) {
				lb_lower_large_loaded_store(&s, store);
			} else {
				lb_lower_large_constant_store(&s, store);
			}
		}

		// NOTE(bill): A field read out of an aggregate value is read where that aggregate came from
		array_clear(&work);
		for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(fn); bb != nullptr; bb = LLVMGetNextBasicBlock(bb)) {
			for (LLVMValueRef i = LLVMGetFirstInstruction(bb); i != nullptr; i = LLVMGetNextInstruction(i)) {
				if (LLVMIsAExtractValueInst(i) && !lb_is_aggregate_type(LLVMTypeOf(i))) {
					array_add(&work, i);
				} else if (LLVMIsASelectInst(i) && LLVMTypeOf(i) == LLVMInt1TypeInContext(m->ctx)) {
					array_add(&work, i);
				} else if (LLVMIsACallInst(i)) {
					array_add(&work, i);
				} else if (LLVMIsASwitchInst(i)) {
					array_add(&work, i);
				}
			}
		}
		for (LLVMValueRef i : work) {
			if (LLVMIsASelectInst(i)) {
				lb_lower_bool_select(&s, i);
				continue;
			}
			if (LLVMIsACallInst(i)) {
				lb_truncate_bool_arguments(&s, i);
				lb_redirect_unselectable_call(&s, i);
				continue;
			}
			if (LLVMIsASwitchInst(i)) {
				lb_lower_small_switch(&s, i);
				continue;
			}
			LLVMValueRef agg = LLVMGetOperand(i, 0);
			unsigned n = LLVMGetNumIndices(i);
			if (n > LB_SCALARIZE_MAX_DEPTH) {
				continue;
			}

			if (!(LLVMIsAConstant(agg)        ||
			      LLVMIsAInsertValueInst(agg) ||
			      LLVMIsASelectInst(agg)      ||
			      LLVMIsAPHINode(agg)         ||
			      (LLVMIsALoadInst(agg) && lb_is_plain_access(agg)))) {
				continue;
			}

			s.store = i;

			LLVMValueRef field = nullptr;
			if (lb_aggregate_field_value(&s, agg, LLVMGetIndices(i), n, &field) && field != nullptr) {
				LLVMReplaceAllUsesWith(i, field);
				LLVMInstructionEraseFromParent(i);
			}
		}

		bool removed = true;
		while (removed) {
			removed = false;
			for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(fn); bb != nullptr; bb = LLVMGetNextBasicBlock(bb)) {
				for (LLVMValueRef i = LLVMGetFirstInstruction(bb); i != nullptr; /**/) {
					LLVMValueRef next = LLVMGetNextInstruction(i);
					if (LLVMGetFirstUse(i) == nullptr &&
					    (LLVMIsAInsertValueInst(i) || LLVMIsAExtractValueInst(i) || LLVMIsASelectInst(i) || LLVMIsAPHINode(i) ||
					     LLVMIsAGetElementPtrInst(i) || (LLVMIsALoadInst(i) && lb_is_plain_access(i)))) {
						LLVMInstructionEraseFromParent(i);
						removed = true;
					}
					i = next;
				}
			}
		}
	}
}
