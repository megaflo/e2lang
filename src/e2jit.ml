(*
 * Copyright (c) 2014, TU Berlin
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *   * Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   * Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *   * Neither the name of the TU Berlin nor the
 *     names of its contributors may be used to endorse or promote products
 *     derived from this software without specific prior written permission.

 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL TU Berlin BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 *)
open E2lang
open E2basicblock

open Llvm
open Llvm_executionengine
open Llvm_target
open Llvm_scalar_opts
open Llvm_analysis

(**
 OCaml interface to the thin C-layer for method invocation
 *)
type method_ptr

external pointer_to_method : ExecutionEngine.t -> Llvm.llvalue -> method_ptr = "LLVMRecompileAndRelinkFunction"

external eval_method_int : method_ptr -> int = "eval_method_int"

external eval_dd : method_ptr -> der_val -> der_val -> unit = "eval_method_dd1"
external eval_ii : method_ptr -> int -> int -> unit = "eval_method_ii"

external eval__i_i : method_ptr -> int -> int = "eval__i_i"
external eval__i_b : method_ptr -> int -> bool = "eval__i_b"

external eval_method_bool : method_ptr -> bool = "eval_method_bool"

external eval_method_float : method_ptr -> float = "eval_method_float"

external eval_method_obj : method_ptr -> 'a = "eval_method_obj"


type jit_compiler = {
  jit_context : llcontext ;
  builder : llbuilder ;

  double_type : lltype ;
  int_type : lltype ;
  bool_type : lltype ;
  dvar_type : lltype ;

  the_module : llmodule ;

  (* Create the JIT. *)
  the_execution_engine : ExecutionEngine.t ;
  the_fpm : [ `Function ] PassManager.t ;
}

(**
 JIT-compiler using llvm
 *) 
let optimizing_jit_compiler = 
  let jit_context = global_context () in

  let builder = builder jit_context in
  let double_type = double_type jit_context in
  let int_type = i32_type jit_context in
  let bool_type = i1_type jit_context in
  let dvar_type = pointer_type double_type in

  let the_module = create_module jit_context "e2lang procedures" in

  (* Create the JIT. *)
  let the_execution_engine = (ignore(initialize_native_target ()) ; ExecutionEngine.create_jit the_module 3) in

  let the_fpm = (
    let fpm = PassManager.create_function the_module in
    (* Set up the optimizer pipeline.  Start with registering info about how the
     * target lays out data structures. *)
    DataLayout.add_to_pass_manager fpm (ExecutionEngine.data_layout the_execution_engine);

    (* Promote allocas to registers. *)
    add_memory_to_register_promotion fpm;

    (* Do simple "peephole" optimizations and bit-twiddling optzn. *)
    add_instruction_combination fpm;

    (* reassociate expressions. *)
    add_reassociation fpm;

    (* Eliminate Common SubExpressions. *)
    add_gvn fpm;

    (* Simplify the control flow graph (deleting unreachable blocks, etc). *)
    add_cfg_simplification fpm;
    
    ignore (PassManager.initialize fpm);
    fpm ) in
  { jit_context ; builder ; double_type ; int_type ; 
    bool_type ; dvar_type ; the_module ; the_execution_engine ;
    the_fpm ;
  }
      
(**
  Every local variable of a e2l procedure needs to be allocated on the stack.
  See http://llvm.org/docs/tutorial/LangImpl7.html
 *)
type var_table = {
  local_int_vars : llvalue array ;
  local_float_vars : llvalue array ;
  local_bool_vars : llvalue array ;
  local_dvar_vars : llvalue array;
}

let build_local_vars proto jit size = 
  let make_ivar i = build_alloca jit.int_type (Printf.sprintf "int%d" i) jit.builder in
  let make_fvar i = build_alloca jit.double_type (Printf.sprintf "flt%d" i) jit.builder in
  let make_bvar i = build_alloca jit.bool_type (Printf.sprintf "bool%d" i) jit.builder in
  let make_dvar i = build_array_alloca jit.double_type size (Printf.sprintf "fltArray%d" i) jit.builder in
  Printf.printf "--- dvars: %d\n%!" proto.dvars;
   { local_int_vars = Array.init proto.ivars make_ivar ; 
     local_bool_vars = Array.init proto.bvars make_bvar; 
     local_float_vars = Array.init proto.fvars make_fvar;
     local_dvar_vars = Array.init proto.dvars make_dvar }

let llvm_type jit = function
    IArg _ -> jit.int_type
  | FArg _ -> jit.double_type
  | BArg _ -> jit.bool_type
  | DArg _ -> jit.dvar_type

let llvm_rettype jit = function
    IRet -> jit.int_type
  | FRet -> jit.double_type
  | BRet -> jit.bool_type
  | DRet -> void_type jit.jit_context 

(* generation *)

(* mapping functions for atoms *)
let build_int_value vt jit = function
    | IntLit n -> const_int jit.int_type n
    | IntVar c -> 
        let pi = vt.local_int_vars.(c) in
        build_load pi "tempInt" jit.builder

let build_float_value vt jit = function
    | FloatLit f -> const_float jit.double_type f
    | FloatVar c -> 
        let pf = vt.local_float_vars.(c) in
        build_load pf "tempFloat" jit.builder

let build_bool_value vt jit = function
    | BoolLit b -> const_int jit.bool_type (if b then 1 else 0)
    | BoolVar c -> 
        let pb = vt.local_bool_vars.(c) in
        build_load pb "tempBool" jit.builder

(* create binary expressions; translates atoms via tf *)
let build_binary_expr f tf v1 v2 str vt jit =
    let tv1 = tf vt jit v1 in
    let tv2 = tf vt jit v2 in
    f tv1 tv2 str jit.builder

let build_int_expr f = 
    build_binary_expr f build_int_value
let build_float_expr f =
    build_binary_expr f build_float_value
let build_bool_expr f =
    build_binary_expr f build_bool_value

(* build single expression *)
let build_expr vt jit = function
    | FAdd (a1, a2)     -> build_float_expr build_fadd a1 a2 "fadd_tmp" vt jit
    | FMul (a1, a2)     -> build_float_expr build_fmul a1 a2 "fmul_tmp" vt jit
    | FCopyI a -> 
            let b = build_int_value vt jit a in
            build_sitofp b jit.double_type "int_to_float" jit.builder
    | FCopy a -> build_float_value vt jit a
    | IAdd (a1, a2)    -> build_int_expr build_add a1 a2 "iadd_tmp" vt jit
    | IEquals (a1, a2) -> build_int_expr (build_icmp Icmp.Eq) a1 a2 "icomp_tmp" vt jit
    | IMul (a1, a2)    -> build_int_expr build_mul a1 a2 "imul_tmp" vt jit 
    | ICopyB a         -> build_bool_value vt jit a
    | ICopy a          -> build_int_value vt jit a
    | BAnd (a1, a2)    -> build_bool_expr build_and a1 a2 "band_tmp" vt jit
    | BOr (a1, a2)     -> build_bool_expr build_or a1 a2 "bor_tmp" vt jit
    | BNot a ->
            let b = build_bool_value vt jit a in
            build_not b "bool_not" jit.builder
    | BCopy a -> build_bool_value vt jit a
    | Call (name,args) -> 
            let callee =
                match lookup_function name jit.the_module with
                | Some callee -> callee (* contains the llvm value of the function *) 
                | None -> raise (Error "unknown function")
            in
            let params = params callee in
            if Array.length params == Array.length args then () else
                raise (Error "incorrect number of arguments");
            let map_args = function (* transform variables in llvm values *)
                | IArg a -> vt.local_int_vars.(a)
                | FArg a -> vt.local_float_vars.(a)
                | BArg a -> vt.local_bool_vars.(a)  
                | DArg a -> vt.local_dvar_vars.(a)
            in
            let arg = Array.map map_args args in (* new array with llvm values *)
            build_call callee arg "call_function" jit.builder 

(* these values are needed for several operations. A globals structs is thus passed to every function from here on (like vt before) *)
type globals = {
    params : llvalue;   (* global variables *)
    order : llvalue;
    size : llvalue;
    bytesize : llvalue;
    tnp_mul : llvalue;  (* global functions from TNP *)
    tnp_add : llvalue;
    tnp_pow : llvalue;
    tnp_const : llvalue;
    tnp_var : llvalue;
    memcpy: llvalue;    (* good old memcpy *)
    tnp_tmp : llvalue option; (* tmp variable for multiplication *)
}

(* build copy instruction *)
let build_copy_array src tgt globals jit =
    let args = [|tgt; src; globals.bytesize|] in
    build_call globals.memcpy args "" jit.builder
    (*let cargs = [|globals.params; globals.order; tgt; const_float jit.double_type 0.|] in
    build_call globals.tnp_const cargs "" jit.builder;
    let args = [|globals.params; globals.order; tgt; src; tgt|] in
    ignore (build_call globals.tnp_add args "" jit.builder)*)

(* build single statement. Uses build_expr *)
let build_stmt vt globals f jit = function
    | Store (FArg var, expr) ->
            let llvexpr = build_expr vt jit expr in
            ignore (build_store llvexpr vt.local_float_vars.(var) jit.builder)
    | Store (IArg var, expr) ->
            let llvexpr = build_expr vt jit expr in
            ignore (build_store llvexpr vt.local_int_vars.(var) jit.builder)
    | Store (BArg var, expr) ->
            let llvexpr = build_expr vt jit expr in
            ignore (build_store llvexpr vt.local_bool_vars.(var) jit.builder)
    | Store (DArg var, DMul (v1, v2)) ->
            (* multiplication has to ensure dst and args are disjoint *)
            let dest =
                if var = v1 || var = v2 then
                    let Some(tmp) = globals.tnp_tmp in
                tmp
                else vt.local_dvar_vars.(var) in
            let args:llvalue array = [|globals.params; globals.order; dest; vt.local_dvar_vars.(v1); vt.local_dvar_vars.(v2)|] in
            build_call globals.tnp_mul args "" jit.builder;
            if var = v1 || var = v2 then ignore(build_copy_array dest vt.local_dvar_vars.(var) globals jit) else ()
    | Store (DArg var, DAdd (v1, v2)) ->
            let args = [|globals.params; globals.order; vt.local_dvar_vars.(var); vt.local_dvar_vars.(v1); vt.local_dvar_vars.(v2)|] in
            ignore (build_call globals.tnp_add args "" jit.builder)
    | Store (DArg var, DPwr (i, v)) ->
            let args = [|globals.params; globals.order; vt.local_dvar_vars.(var); vt.local_dvar_vars.(v); build_int_value vt jit i|] in
            ignore (build_call globals.tnp_pow args "" jit.builder)
    | Store (DArg var, DLoadF f) ->
            let args = [|globals.params; globals.order; vt.local_dvar_vars.(var); build_float_value vt jit f|] in
            ignore (build_call globals.tnp_const args "" jit.builder)
    | Store (DArg var, DCopy v) ->
            ignore(build_copy_array vt.local_dvar_vars.(v) vt.local_dvar_vars.(var) globals jit)
    | Ret (FArg var) ->
            let retval = build_float_value vt jit (FloatVar var) in
            ignore (build_ret retval jit.builder)
    | Ret (IArg var) ->
            let retval = build_int_value vt jit (IntVar var) in
            ignore (build_ret retval jit.builder)
    | Ret (BArg var) ->
            let retval = build_bool_value vt jit (BoolVar var) in
            ignore (build_ret retval jit.builder)
    | Ret (DArg var) ->
            (* DVars are returned via out argument *)
            let params = params f in
            let last_arg = Array.get params ((Array.length params) - 1) in
            build_copy_array vt.local_dvar_vars.(var) last_arg globals jit;
            ignore (build_ret_void jit.builder)
    | _ -> ()


let build_stmts vt globals f jit bb = 
    Array.iter ( build_stmt vt globals f jit ) bb.stmts

(* build llvm basic block *)
let build_new_block vt globals jit bb f =
    let new_block = append_block jit.jit_context bb.name f in
    position_at_end new_block jit.builder;
    build_stmts vt globals f jit bb;
    StrMap.add bb.name new_block

let build_llvm_blocks vt globals jit blist f =
    List.fold_left (fun map bb -> build_new_block vt globals jit bb f map) StrMap.empty blist

(* connect llvm basic block *)
let build_link jit map vt bb = 
    let llvm_block = StrMap.find bb.name map in 
    position_at_end llvm_block jit.builder;
    match(bb.next) with
         NoBlock -> ()
       | OneBlock s -> 
            let next_block = StrMap.find s map in
            ignore (build_br next_block jit.builder) 
       | CondBlocks (i,s1,s2) -> 
            let var = vt.local_bool_vars.(i) in
            let bool_val = build_load var "tempBool" jit.builder in
            let next_block_1 = StrMap.find s1 map in
            let next_block_2 = StrMap.find s2 map in  
            ignore (build_cond_br bool_val next_block_1 next_block_2 jit.builder) 

let build_links jit map vt = 
    List.iter ( build_link jit map vt )

(* build instructions to load arguments to stack variables *)
let build_store_param jit params vt globals pidx = Printf.printf "pidx=%d, params.length=%d\n%!" pidx (Array.length params);function
    | IArg i -> ignore (build_store params.(pidx) vt.local_int_vars.(i) jit.builder)
    | FArg i -> ignore (build_store params.(pidx) vt.local_float_vars.(i) jit.builder)
    | BArg i -> ignore (build_store params.(pidx) vt.local_bool_vars.(i) jit.builder)
    | DArg i -> ignore (build_copy_array params.(pidx) vt.local_dvar_vars.(i) globals jit)

let build_store_params jit proto params vt globals =
    Array.iteri (build_store_param jit params vt globals) proto.args

(* build function declaration *)
let build_function_decl jit proto name =
    let llargs = Array.concat [Array.map (llvm_type jit) proto.args; if proto.ret == DRet then [|jit.dvar_type|] else [||]] in
    let ft = function_type (llvm_rettype jit proto.ret) llargs in
    declare_function name ft jit.the_module

(* and definition *)
let build_function_def jit f blist proto globals =
    let init_block = append_block jit.jit_context "init" f in
    let _ = position_at_end init_block jit.builder in
   
    (* globals loaded to be accessible *)
    let par = build_load globals.params "params" jit.builder in
    let ord = build_load globals.order "order" jit.builder in
    let size = build_load globals.size "size" jit.builder in
    let bytesize = build_shl size (const_int jit.int_type 3) "bytesize" jit.builder in 
    let tmp = build_array_alloca jit.double_type size "tmp" jit.builder in
    let newglobals = {params=par; order=ord; size=globals.size; bytesize=bytesize; tnp_add=globals.tnp_add;tnp_mul=globals.tnp_mul;tnp_pow=globals.tnp_pow;tnp_const=globals.tnp_const;tnp_var=globals.tnp_var;memcpy=globals.memcpy;tnp_tmp=Some(tmp)} in

    let vt = build_local_vars proto jit size in
    Printf.printf "Post vartable\n%!";
    let _ = build_store_params jit proto (params f) vt newglobals in
    Printf.printf "Post store params\n%!";
    let map = build_llvm_blocks vt newglobals jit blist f in
    Printf.printf "Post build_llvm_blocks\n%!";
    build_links jit map vt blist;
    position_at_end init_block jit.builder;
    build_br (StrMap.find "start" map) jit.builder;
    Llvm_analysis.assert_valid_function f;
    (*dump_value(f);*)
    PassManager.run_function f jit.the_fpm;
    f

(* probably not needed anymore; does the work of build*_decl and build*_def *)
let build_function jit blist proto name globals = 
    let llargs = Array.concat [Array.map (llvm_type jit) proto.args; if proto.ret == DRet then [|jit.dvar_type|] else [||]] in
    let ft = function_type (llvm_rettype jit proto.ret) llargs in
    let f = declare_function name ft jit.the_module in
    let init_block = append_block jit.jit_context "init" f in
    let _ = position_at_end init_block jit.builder in
    
    let par = build_load globals.params "params" jit.builder in
    let ord = build_load globals.order "order" jit.builder in
    let size = build_load globals.size "size" jit.builder in
    let bytesize = build_shl size (const_int jit.int_type 3) "bytesize" jit.builder in 
    let tmp = build_array_alloca jit.double_type size "tmp" jit.builder in
    let newglobals = {params=par; order=ord; size=globals.size; bytesize=bytesize; tnp_add=globals.tnp_add;tnp_mul=globals.tnp_mul;tnp_pow=globals.tnp_pow;tnp_const=globals.tnp_const;tnp_var=globals.tnp_var;memcpy=globals.memcpy;tnp_tmp=Some(tmp)} in

    let vt = build_local_vars proto jit size in
    let _ = build_store_params jit proto (params f) vt newglobals in
    let map = build_llvm_blocks vt newglobals jit blist f in
    build_links jit map vt blist;
    position_at_end init_block jit.builder;
    build_br (StrMap.find "start" map) jit.builder;
    Llvm_analysis.assert_valid_function f;
    (*dump_value(f);*)
    (*PassManager.run_function f jit.the_fpm;*)
    f

(* define global variables size,params and order *)
let build_module_preamble jit = 
    let param = define_global "params" (const_int jit.int_type 0) jit.the_module in
    let order = define_global "order" (const_int jit.int_type 0) jit.the_module in
    let size = define_global "size" (const_int jit.int_type 1) jit.the_module in
    (* define set_meta *)
    let ft = function_type (void_type jit.jit_context) [|jit.int_type; jit.int_type|] in
    let set_meta = declare_function "set_meta" ft jit.the_module in
    let init_block = append_block jit.jit_context "init" set_meta in
    position_at_end init_block jit.builder;
    build_store (params set_meta).(0) param jit.builder;
    build_store (params set_meta).(1) order jit.builder;
    let p1 = build_add (params set_meta).(0) (const_int jit.int_type 1) "columns" jit.builder in
    let o1 = build_add (params set_meta).(1) (const_int jit.int_type 1) "rows" jit.builder in
    let temps = build_mul p1 o1 "size" jit.builder in
    build_store temps size jit.builder;
    build_ret_void jit.builder;
    Llvm_analysis.assert_valid_function set_meta;
    (* declare globals *)
    let binopt = function_type (void_type jit.jit_context) [|jit.int_type; jit.int_type; jit.dvar_type; jit.dvar_type; jit.dvar_type|] in
    let addf = declare_function "op_tnp_number_add" binopt jit.the_module in
    let mulf = declare_function "op_tnp_number_mult" binopt jit.the_module in
    let powt = function_type (void_type jit.jit_context) [|jit.int_type; jit.int_type; jit.dvar_type; jit.dvar_type; jit.int_type |] in
    let powf = declare_function "op_tnp_number_pow" powt jit.the_module in
    let constt = function_type (void_type jit.jit_context) [|jit.int_type; jit.int_type; jit.dvar_type; jit.double_type|] in
    let constf = declare_function "op_tnp_number_write_constant" constt jit.the_module in
    let vart = function_type (void_type jit.jit_context) [|jit.int_type; jit.int_type; jit.dvar_type; jit.double_type; jit.int_type |] in
    let varf = declare_function "op_tnp_number_write_variable" vart jit.the_module in
    let copyt = function_type (void_type jit.jit_context) [|jit.dvar_type; jit.dvar_type; jit.int_type|] in
    let copyf = declare_function "memcpy" copyt jit.the_module in
    {params=param;order;size;bytesize=size;tnp_add=addf;tnp_mul=mulf;tnp_pow=powf;tnp_const=constf;tnp_var=varf;memcpy=copyf;tnp_tmp=None}

(* build whole module (preamble + functions) *)
let build_module fmap =
    let jit = optimizing_jit_compiler in
    let globals = build_module_preamble jit in
    (*let f = build_function jit bbs proto "test" globals in*)
    let fts = StrMap.mapi (fun name (proto, bbs) -> (build_function_decl jit proto name, proto, bbs)) fmap in
    StrMap.iter (fun name (f, proto, bbs) -> (build_function_def jit f bbs proto globals; ())) fts;
    (*let m = pointer_to_method jit.the_execution_engine f in*)
    dump_module jit.the_module;
    ()(*let Some(set_meta) = lookup_function "set_meta" jit.the_module in
    eval_ii (pointer_to_method jit.the_execution_engine set_meta) 1 0;
    let ret = [|0.; 0.|] in
    eval_dd m [|2.; 3.5|] ret;
    Printf.printf "(%f, %f)\n%!" ret.(0) ret.(1)*)

(* read function pointer from module; this does the actual compiling if neccessary *)
let get_pointer name =
    let jit = optimizing_jit_compiler in
    let Some(func) = lookup_function name jit.the_module in
    pointer_to_method jit.the_execution_engine func







