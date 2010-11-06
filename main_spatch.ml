
(*
 * The author disclaims copyright to this source code.  In place of
 * a legal notice, here is a blessing:
 *
 *    May you do good and not evil.
 *    May you find forgiveness for yourself and forgive others.
 *    May you share freely, never taking more than you give.
 *)

open Common

open Ast_php

module Ast = Ast_php
module V = Visitor_php

module Ast2 = Ast_js
module V2 = Visitor_js

module PI = Parse_info

(*****************************************************************************)
(* Purpose *)
(*****************************************************************************)

(* 
 * A syntactical patch for PHP.
 * 
 * opti: git grep xxx | xargs spatch_php ...
 * 
 * 
 * Alternatives: 
 *  - you could also just write a sgrep that put a special mark to the 
 *    place where it matched and then do the transformation using an 
 *    emacs macro leveraging those marks.
 *)

(*****************************************************************************)
(* Flags *)
(*****************************************************************************)

let verbose = ref true

let apply_patch = ref false

let spatch_file = ref ""

(* action mode *)
let action = ref ""


(*****************************************************************************)
(* Wrappers *)
(*****************************************************************************)
let pr2 s = 
  if !verbose then Common.pr2 s

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let apply_transfo (f, keywords_grep_opt) xs =

  let files = Lib_parsing_php.find_php_files_of_dir_or_files xs in

  let pbs = ref [] in
  (* xhp and transformation was not mixing well, but now it's better
   * thanks to builtin xhp support
   *)

  Flag_parsing_php.show_parsing_error := false;
  Flag_parsing_php.verbose_lexing := false;

  let nbfiles = List.length files in

  Common.execute_and_show_progress ~show_progress:true nbfiles (fun k ->
  files +> List.iter (fun file ->
    let file = Common.relative_to_absolute file in
    pr2 (spf "processing: %s" file);

    k();

    let worth_trying = 
      match keywords_grep_opt with
      | None -> true
      | Some xs -> Common.contain_any_token_with_egrep xs file
    in
    if not worth_trying then ()
    else
    try (
    let (ast2, _stat) = Parse_php.parse file in
    let ast = Parse_php.program_of_program2 ast2 in
    Lib_parsing_php.print_warning_if_not_correctly_parsed ast file;

    let was_modified = f ast in

    (* old: 
     * let patch = Patch.generate_patch !edition_cmds 
     * ~filename_in_project:file file in
     * patch |> List.iter pr
     *)

    if was_modified then begin 
      let s = Unparse_php.string_of_program2_using_tokens ast2 in
    
      let tmpfile = Common.new_temp_file "trans" ".php" in
      Common.write_file ~file:tmpfile s;
      
      let diff = Common.cmd_to_list (spf "diff -u %s %s" file tmpfile) in
      diff |> List.iter pr;

      if !apply_patch 
      then Common.write_file ~file:file s;
    end
    ) with exn ->
      Common.push2 (spf "PB with %s, exn = %s" file (Common.exn_to_s exn)) pbs;
  ));
  !pbs +> List.iter Common.pr2



let apply_transfo_js (f, keywords_grep_opt) xs =

  let files = Lib_parsing_js.find_js_files_of_dir_or_files xs in

  let pbs = ref [] in

  let nbfiles = List.length files in

  Common.execute_and_show_progress ~show_progress:true nbfiles (fun k ->
  files +> List.iter (fun file ->
    let file = Common.relative_to_absolute file in
    pr2 (spf "processing: %s" file);

    k();

    let worth_trying = 
      match keywords_grep_opt with
      | None -> true
      | Some xs -> Common.contain_any_token_with_egrep xs file
    in
    if not worth_trying then ()
    else
    try (
    let (ast2, _stat) = Parse_js.parse file in
    let ast = Parse_js.program_of_program2 ast2 in
    (* Lib_parsing_php.print_warning_if_not_correctly_parsed ast file; *)

    let was_modified = f ast in

    (* old: 
     * let patch = Patch.generate_patch !edition_cmds 
     * ~filename_in_project:file file in
     * patch |> List.iter pr
     *)

    if was_modified then begin 
      let s = Unparse_js.string_of_program2_using_tokens ast2 in
    
      let tmpfile = Common.new_temp_file "trans" ".php" in
      Common.write_file ~file:tmpfile s;
      
      let diff = Common.cmd_to_list (spf "diff -u %s %s" file tmpfile) in
      diff |> List.iter pr;

      if !apply_patch 
      then Common.write_file ~file:file s;
    end
    ) with exn ->
      Common.push2 (spf "PB with %s, exn = %s" file (Common.exn_to_s exn)) pbs;
  ));
  !pbs +> List.iter Common.pr2


 
(*****************************************************************************)
(* Main action *)
(*****************************************************************************)
(* 
 ./spatch -c tests/php/spatch/foo.spatch tests/php/spatch/foo.php  
*)

(* just to test the backend part of spatch *)
let (dumb_spatch_pattern: Ast_php.expr) = 
  (* ./pfff -dump_php_ml tests/php/spatch/1.php *)
  let i_1 = {
    pinfo =
      PI.OriginTok(
        { PI.str = "1"; charpos = 6; line = 2; column = 0; 
          file = "tests/php/spatch/1.php"; 
        });
     comments = (); 
     (* the spatch is to replace every 1 by 42 *)
     transfo = Replace (AddStr "42");
    }
  in
  let t_1 = Ast.noType () in
  (Sc(C(Int(("1", i_1)))), t_1)

(*
 * Here is an example of a spatch file:
 * 
 *    foo(2, 
 * -      bar(2)
 * +      foobar(4)
 *       )
 * 
 * This will replace all calls to bar(2) by foobar(4) when
 * the function call is the second argument of a call to
 * foo where its first argument is 2.
 * 
 * Algorithm to parse a spatch file:
 *  - take lines of the file, index the lines
 *  - replace the + lines by an empty line and remember in a line_env
 *    the line and its index
 *  - remove the - in the first column and remember in a line_env
 *    that is was a minus line
 *  - unlines the filtered lines into a new string 
 *  - call the PHP expr parser on this new string
 *  - go through all tokens and adjust its transfo field using the
 *    information in line_env
 *)
type line_kind = 
  | Context
  | Plus of string
  | Minus

let parse_spatch file =

  let xs = Common.cat file +> Common.index_list_1 in

  let hline_env = Hashtbl.create 11 in

  let ys = xs +> List.map (fun (s, lineno) ->
    match s with
    (* ugly: for now I strip the space after the + because.
     * at some point we need to parse this stuff and
     * add the correct amount of indentation when it's processing
     * a token.
     *)
    | _ when s =~ "^\\+[ \t]*\\(.*\\)" -> 
        let rest_line = Common.matched1 s in
        Hashtbl.add hline_env lineno (Plus rest_line);
        ""
    | _ when s =~ "^\\-\\(.*\\)" ->
        let rest_line = Common.matched1 s in
        Hashtbl.add hline_env lineno Minus;
        rest_line
    | _ ->
        Hashtbl.add hline_env lineno Context;
        s
  )
  in
  let spatch_without_patch_annot = Common.unlines ys in
  (* pr2 spatch_without_patch_annot; *)

  let pattern = 
    (* ugly *)
    if spatch_without_patch_annot =~ "^[ \t]*<"
    then Parse_php.xhp_expr_of_string spatch_without_patch_annot 
    else Parse_php.expr_of_string spatch_without_patch_annot 
  in

  (* need adjust the tokens in it now *)
  let toks = Lib_parsing_php.ii_of_any (Expr pattern) in

  (* adjust with Minus info *)  
  toks +> List.iter (fun tok ->
    let line = Ast.line_of_info tok in

    (* ugly: right now expr_of_string introduce an extra <?php at
     * the beginning which shifts line number by 1 so have
     * to compensate back here.
     *)
    let line = line - 1 in

    let annot = Hashtbl.find hline_env line in
    (match annot with
    | Context -> ()
    | Minus -> tok.transfo <- Remove;
    | Plus _ -> 
        (* normally impossible since we removed the elements in the
         * plus line, except the newline. should assert it's only newline
         *)
        ()
    );
  );
  (* adjust with the Plus info. We need to annotate the last token
   * on the preceding line or next line.
   * e.g. on
   *     foo(2,
   *   +        42,
   *         3)
   * we could either put the + on the ',' of the first line (as an AddAfter)
   * or on the + on the '3' of the thirdt line (as an AddBefore).
   * The preceding and next line could also be a minus line itself.
   * Also it could be possible to have multiple + line in which
   * case we want to concatenate them together.
   * 
   * TODO: for now I just associate it with the previous line ...
   *)

  let grouped_by_lines = 
    toks +> Common.group_by_mapped_key (fun tok -> Ast.line_of_info tok) in
  let rec aux xs = 
    match xs with
    | (line, toks_at_line)::rest ->
        (* ugly *)
        let line = line - 1 in

        (* if the next line was a +, then associate with the last token
         * on this line
         *)
        (match Common.hfind_option (line+1) hline_env with
        | None -> 
            (* probably because was last line *) 
            ()
        | Some (Plus toadd) ->
            (* todo? what if there is no token on this line ? *)
            let last_tok = Common.last toks_at_line in
            (match last_tok.transfo with
            | Remove -> last_tok.transfo <- Replace (AddStr toadd)
            | NoTransfo -> last_tok.transfo <- AddAfter (AddStr toadd)
            | _ -> raise Impossible
            )
        | Some _ -> ()
        );
        aux rest

    | [] -> ()
  in
  aux grouped_by_lines;

  (* both the ast (here pattern) and the tokens share the same
   * reference so by modifying the tokens we actually also modifed
   * the AST.
   *)
  pattern
   



let main_action xs =

  if Common.null_string !spatch_file
  then failwith "I need a semantic patch file; use -c";

  let spatch_file = !spatch_file in

  (* old: let pattern = dumb_spatch_pattern in *)
  let pattern = parse_spatch spatch_file in

  let files = Lib_parsing_php.find_php_files_of_dir_or_files xs in
  files +> Common.index_list_and_total +> List.iter (fun (file, i, total) ->
    pr2 (spf "processing: %s (%d/%d)" file i total);

    let was_modifed = ref false in
    
    (* quite similar to what we do in main_sgrep.ml *)
    let (ast2, _stat) = Parse_php.parse file in
    let ast = Parse_php.program_of_program2 ast2 in
    Lib_parsing_php.print_warning_if_not_correctly_parsed ast file;

    let visitor = V.mk_visitor { V.default_visitor with
      (* for now handle only expression patching *)
      V.kexpr = (fun (k, _) x ->
        let matches_with_env =  
          Matching_php.match_e_e pattern  x
        in
        if matches_with_env = []
        then k x
        else begin
          was_modifed := true;
          Transforming_php.transform_e_e pattern x
            (* TODO, maybe could get multiple matching env *)
            (List.hd matches_with_env) 
        end
      );
    }
    in
    visitor (Program ast);
    
    if !was_modifed then begin
      let s = Unparse_php.string_of_program2_using_tokens ast2 in
      
      let tmpfile = Common.new_temp_file "trans" ".php" in
      Common.write_file ~file:tmpfile s;
      
      let diff = Common.cmd_to_list (spf "diff -u %s %s" file tmpfile) in
      diff |> List.iter pr;

      if !apply_patch 
      then Common.write_file ~file:file s;
    end
  )


(*****************************************************************************)
(* Extra actions *)
(*****************************************************************************)

(* -------------------------------------------------------------------------*)
(* send_mail refactoring *)
(* -------------------------------------------------------------------------*)

(* this is hard to implement such a refactoring in a semantic patch. There
 * is probably too much logic needed. Or maybe the semantic patch language
 * is not flexible enough.
 *)

let send_mail_default_args = [
  "from_addr"                , "'noreply@facebookmail.com'";
  "from_name"                , "'Facebook'";
  "contact_email"            , "0";
  "reply_to_name"            , "''";
  "reply_to_addr"            , "''";
  "addheaders"               , "''";
  "is_html"                  , "false";
  "to_name"                  , "''";
  "high_priority"            , "false";
  "embedded_images"          , "null";
  "alt_body"                 , "''";
  "bcc"                      , "null";
  "attachments"              , "''";
  "bypass_unreachable_check" , "false";
  "mail_type"                , "''";
  "from_async"               , "false";
  "mid"                      , "''";
  "cc"                       , "null";
  "bcc_dev"                  , "true";
]

let send_mail_all_args = 
  ["to"; "subj"; "body";] ++ (Common.keys send_mail_default_args)

let send_mail_field_name s = 
  Common.global_replace_regexp "_\\([a-z]\\)" (fun sub ->
    let letter = Common.matched1 s in
    String.capitalize letter
  ) s
let send_mail_method_name s = 
  send_mail_field_name s |> String.capitalize

let _ = example (send_mail_field_name "from_addr" = "fromAddr")
let _ = example (send_mail_method_name "from_addr" = "FromAddr")


let send_mail_transfo_func ast = 

    let was_modified = ref false in

    (* ugly hack to have some form of poor's man dataflow for variables *)
    let current_vars_and_assignements = ref [] in
    
    let hook = { V.default_visitor with

      (* todo: this is not enough, we also need to reset it at a few places *)
      V.kfunc_def = (fun (k, _) def ->
        let body = def.f_body in
        current_vars_and_assignements := Lib_parsing_php.get_vars_assignements 
          (fun vout -> vout (Body body));
        k def;
      );
      V.kclass_stmt = (fun (k, _) x ->
        match x with
        | Method def -> 
            (match def.m_body with
            | AbstractMethod _ -> ()
            | MethodBody body -> 
                
                current_vars_and_assignements := Lib_parsing_php.get_vars_assignements 
                  (fun vout -> vout (Body body));
                k x;
            )
        | XhpDecl _ -> k x
        | ClassConstants _ | ClassVariables _ -> k x
      );

      
      V.klvalue = (fun (k, _) x ->
        match Ast.untype x with
        | FunCallSimple((Name ("send_mail", info)), (lp, args, rp)) ->
          (* we assume there is no call to send_mail in send_mail args itself *)

          was_modified := true;
          if !verbose then 
            Lib_parsing_php.print_match ~format:Lib_parsing_php.Emacs
              (Lib_parsing_php.ii_of_any (Lvalue x));

          (match Ast.uncomma args with
          | (Arg to_expr)::(Arg subj_expr)::(Arg body_expr)::default_args ->

              (* 1: remove the lines *)
              let toks = Lib_parsing_php.ii_of_any (Lvalue x) in
              toks |> List.iter (fun info -> info.transfo <- Ast.Remove);

              (* 2: add lines for first 3 arguments *)
              let toadd = ref (
                spf "id(new MailSender(%s, %s, %s))" 
                (Unparse_php.string_of_expr to_expr)
                (Unparse_php.string_of_expr subj_expr)
                (Unparse_php.string_of_expr body_expr)
              )
              in

              (* 3: processing further arguments to determine whether
               * they are the same than the default one or whether
               * we need to add extra method calls *)
              if (List.length default_args > List.length send_mail_default_args)
              then failwith "this call to send_mail has too many arguments";

              Common.zip_safe default_args send_mail_default_args |> 
                List.iter (fun (arg, (default_arg_name, default_arg_expr_s)) ->
                  match arg with
                  | Arg e ->
                      let default_arg_expr = 
                        Parse_php.expr_of_string default_arg_expr_s in
                      if Matching_php.match_e_e default_arg_expr e <> []
                      then 
                          pr2 (spf "default arg for %s is matching" 
                                  default_arg_name)
                      else
                        (* may be a variable that were assigned a single
                         * value. It requires a data-flow analysis but
                         * as a first step just hard coding a few
                         * stuff might be enough.
                         *)
                        let is_matching_via_data_flow = 
                          (match Ast.untype e with
                          | Lv v ->
                            (match Ast.untype v with
                            | Var (dname, _scope) ->
                                let s = Ast.dname dname in
                                let assigns = 
                                  try 
                                    Common.assoc s !current_vars_and_assignements
                                  with
                                  Not_found -> []
                                in
                                (match assigns with
                                | [e] -> 
                                    Matching_php.match_e_e default_arg_expr e
                                      <> []
                                | _ -> false
                                )
                            | _ -> false
                            )
                          | _ -> false
                          )
                        in
                        if is_matching_via_data_flow
                        then 
                          pr2 (spf "default arg for %s is matching via flow analysis" 
                                  default_arg_name)
                        else begin
                          pr2 (spf "default arg for %s is not matching" 
                                  default_arg_name);

                          let newadd = 
                            spf "\n\t->set%s(%s)" 
                              (send_mail_method_name default_arg_name)
                              (Unparse_php.string_of_expr e)
                          in
                          toadd := !toadd ^ newadd;
                        end
                  | _ -> 
                      failwith "wrong call to send_mail"
                );
              toadd := !toadd ^ "\n\t->execute()";
              info.transfo <- Ast.Replace (Ast.AddStr !toadd);


          | _ -> 
              (* could replace with a failwith *)
              pr2 "send_mail has not enough arguments"
          )

        | _ ->
            (* recurse *)
            k x
      );
    }
    in
    (* opti ? dont analyze func if no constant in it ?*)
    (V.mk_visitor hook) (Program ast);

    !was_modified

let send_mail_transfo = send_mail_transfo_func, Some ["send_mail"]


let send_mail_def_transfo_func ast = 

  let hook = { V.default_visitor with
    V.kfunc_def = (fun (k, _) def -> 
      let s = Ast.name def.f_name in 
      let info = Ast.info_of_name def.f_name in
      if s = "send_mail"
      then begin
        (* removing the header of the function (name and params) *)
        let ii =
          [def.f_tok] ++
          [Ast.info_of_name def.f_name] ++
          Lib_parsing_php.ii_of_any (Parameters def.f_params)
        in
        ii |> List.iter (fun info ->
          info.transfo <- Ast.Remove
        );
        let toadd = spf
"\nclass MailSender {
  private
%s;

  // required parameters on __construct	
  public function __construct($to, $subj, $body) {
     $this->to = $to;
     $this->subj = $subj;
     $this->body = $body;

%s
  }
%s
  public function execute()
"
          (* private vars *)
          (send_mail_all_args |> List.map (fun s -> 
            spf "    $%s,\n" (send_mail_field_name s)
          ) |> Common.join "")
          (* default arg assignement *)
          (send_mail_default_args |> List.map (fun (s, default) ->
            spf "     $this->%s = %s;\n" (send_mail_field_name s) default
          ) |> Common.join "")
          (* method code *)
          (send_mail_default_args |> List.map (fun (s, default) ->
            spf "public function set%s($%s) {
     $this->%s = $%s;
     return $this;
  }
"
              (send_mail_method_name s)
              s
              (send_mail_field_name s)
              s
          ) |> Common.join "")
        in
        info.transfo <- Ast.Replace (Ast.AddStr toadd);

        k def
      end
    );
    V.klvalue = (fun (k, _) x ->
        match Ast.untype x with
        | Var(dname, _scoperef) ->
            let s = Ast.dname dname in
            let info = Ast.info_of_dname dname in
            if List.mem s send_mail_all_args
            then begin
              let fld = spf "$this->%s" (send_mail_field_name s) in
              info.transfo <- Ast.Replace (Ast.AddStr fld);
            end
        | _ -> k x
      );
  }
  in
  (V.mk_visitor hook) (Program ast);
  true (* was modified *)

let send_mail_def_transfo = send_mail_def_transfo_func, Some ["send_mail"]

(* -------------------------------------------------------------------------*)
(* fn_idx refactoring *)
(* -------------------------------------------------------------------------*)

let fn_idx_transfo_func ast = 

    let was_modified = ref false in

    let hook = { V.default_visitor with

      V.klvalue = (fun (k, _) x ->
        match Ast.untype x with
        | FunCallSimple((Name ("fn_idx", fn_idx_info)), (lp, args, rp)) ->

          was_modified := true;
          if !verbose then 
            Lib_parsing_php.print_match ~format:Lib_parsing_php.Emacs
              (Lib_parsing_php.ii_of_any (Lvalue x));


          (match args with
          | [Left (Arg expr1); Right comma; Left (Arg expr2)] ->

              (* fn_idx(Expr1, expr2)) -> Expr1[expr2] *)
              fn_idx_info.transfo <- Ast.Remove;
              lp.transfo <- Ast.Remove;
              comma.transfo <- Ast.Replace (Ast.AddStr "[");
              rp.transfo <- Ast.Replace (Ast.AddStr "]");
              

              (* old: was simpler, but had indentation pbs. To reput
               * at some point.
               * 
               * 1: remove the tokens of the funcalls *
               * let toks = Lib_parsing_php.ii_of_lvalue x in
               * toks |> List.iter (fun info -> info.transfo <- Ast.Remove);
               * 
               * 2: add expr[expr2] 
               * 
               * let toadd = 
               * spf "(%s)[%s]"
               * (Unparse_php.string_of_expr expr1)
               * (Unparse_php.string_of_expr expr2)
               * in
               * info.transfo <- Ast.Replace (Ast.AddStr toadd);
               *)

              
          | _ -> 
              failwith "fn_idx has not enough arguments"
          )
        | _ ->
            (* recurse *)
            k x
      );
    }
    in
    (V.mk_visitor hook) (Program ast);

    !was_modified

let fn_idx_transfo = fn_idx_transfo_func, None

(* -------------------------------------------------------------------------*)
(* preparer refactoring *)
(* -------------------------------------------------------------------------*)

(* semantic patch:
 *
 * class X extends Preparable {
 * ...
 * function prepare($ARG1, $PREPARER) {
 * ...
 * - $PREPARER
 * + $this
 * ...
 * }
 *)

let replace_dname olds news = 
  V.mk_visitor
  { V.default_visitor with
    V.klvalue = (fun (k, bigf) x ->
      match Ast.untype x with
      | Var (dname, _scope) ->
          let s = Ast.dname dname in
          let info = Ast.info_of_dname dname in
          if s = olds 
          then begin
            info.transfo <- Ast.Replace (Ast.AddStr news);
          end
      | _ -> k x
    )
  }

let replace_dname_waitFor_or_runSiblings preparer_name = 
  V.mk_visitor { V.default_visitor with
    V.klvalue = (fun (k, _) x ->
      match x with
      (* pattern generated by pfff/meta/ffi -dump_php_ml 
       * tests/misc/method_calls2.php
       *)
      | (MethodCallSimple(
          (Var(DName((preparer_str, tok_preparer)), _), tlval_3), i_4,
                 Name((smethod, i_5)),
          (i_6, xs, i_9)),
        tlval_10) ->
          
          if List.mem smethod ["waitFor"; "runSibling"]
          then 
            if preparer_str = preparer_name
            then tok_preparer.transfo <- Ast.Replace (Ast.AddStr "$this")
      | _ -> k x
    )
  }
            

let preparer_transfo_func ast = 

  let was_modified = ref false in

  ast |> List.iter (function
  | ClassDef def ->
      (match def.c_extends with
      | Some (tok, (Name ("Preparable", info))) ->

          def.c_body |> Ast.unbrace |> List.iter (fun class_stmt ->
            (match class_stmt with
            | Method mdef ->
                let s = Ast.name mdef.m_name in
                if s = "prepare"
                then 
                  (match (mdef.m_params |> Ast.unparen |> Ast.uncomma) with
                  | [a;b] ->
                      was_modified := true;
                      let name_second_param = 
                        Ast.dname b.p_name
                      in
                      pr2 (spf "Name of parameter: %s" name_second_param);
                       
                      (replace_dname_waitFor_or_runSiblings
                          name_second_param) (ClassStmt class_stmt);
                  | _ -> 
                      pr2 "wrong number of argument to prepare method"
                  )

            | _ -> ()
            )
          );
      | _ -> ()
      )
  | _ -> ()
  );

  !was_modified

let preparer_transfo = preparer_transfo_func, Some ["prepare"]

let preparer_transfo_bis_func ast = 

  let was_modified = ref false in

  ast |> List.iter (function
  | ClassDef def ->
      (match def.c_extends with
      | Some (tok, (Name ("Preparable", info))) ->
          def.c_body |> Ast.unbrace |> List.iter (fun class_stmt ->
            (match class_stmt with
            | Method mdef ->
                let s = Ast.name mdef.m_name in
                if s = "prepare"
                then 
                  (match (mdef.m_params |> Ast.unparen) with
                  | [Left a; Right comma; Left b] ->
                      was_modified := true;
                      let name_second_param = 
                        Ast.dname b.p_name
                      in
                      pr2 (spf "Name of parameter: %s" name_second_param);

                      let ii = Lib_parsing_php.ii_of_any (Parameter b) in
                      let ii = comma::ii in

                      let all_vars_used = 
                        Lib_parsing_php.get_vars (fun vout -> 
                          vout (ClassStmt class_stmt))
                      in
                      let all_vars = all_vars_used |> List.map Ast.dname in
                      if List.mem name_second_param all_vars
                      then
                        pr2 (spf "%s is still in use" name_second_param)
                      else begin
                        ii |> List.iter (fun info ->
                          info.transfo <- Ast.Remove;
                        );
                      end;
                      ()
                  | [x] -> 
                      (* already transformed *)
                      ()

                  | _ -> 
                      failwith ("Wrong number of arguments to prepare method")
                  )
            | _ -> ()
            )
          );
      | _ -> ()
      )
  | _ -> ()
  );

  !was_modified

let preparer_transfo_bis = preparer_transfo_bis_func, Some ["prepare"]

(* -------------------------------------------------------------------------*)
(* javascript event refactoring *)
(* -------------------------------------------------------------------------*)

let event_transfo_func ast = 

  let was_modified = ref false in

  let hook = { V2.default_visitor with
    V2.kexpr = (fun (k, _) x ->
      match Ast2.untype x with
      | Ast2.This tok ->
          (* test:
          tok.Ast2.transfo <- Ast2.Replace (Ast2.AddStr "THIS");
          was_modified := true;
          *)
          ()

      (* XXX.listen(YYY) ->  Event.listen(XXX, YYY)
         so minus on ., listen, (,  and + before XXX and add a comma after removed '(
      *)
      | Ast2.Apply (e, (lpar, es, rpar)) ->
          (match Ast2.untype e with
          | Ast2.Period (e, tok_period, ("listen", info_listen)) ->
              (match Ast.untype e with
              | Ast2.V ("Event", _) -> 
                  k x
              | _ ->
                  (match Lib_parsing_js.ii_of_expr e with
                  | ii::rest ->
                      was_modified := true;
                      tok_period.PI.transfo <- PI.Remove;
                      info_listen.PI.transfo <- PI.Remove;
                      lpar.PI.transfo <- PI.Replace (PI.AddStr ", ");
                      ii.PI.transfo <- PI.AddBefore (PI.AddStr "Event.listen(");
                      
                  | [] -> failwith "NO II before ."
                  )
              )
          | _ -> k x
          )
      | _ -> k x
    );
  }
  in
  (V2.mk_visitor hook).V2.vprogram ast;
  !was_modified

let event_transfo = event_transfo_func, Some ["listen"]

(* -------------------------------------------------------------------------*)
(* type hint removal refactoring *)
(* -------------------------------------------------------------------------*)

let is_backward_compatible hint = 
  not (List.mem hint ["int"; "bool"; "float"; "string"; 
                           "void"; "mixed";
                           "scalar"; "number";])

let type_hints_removal_transformation ast =

  let was_modified = ref false in

  let remove_type_hint_tokens type_hint =
    let info =
      match type_hint with
      | HintArray info -> info
      | Hint name -> Ast.info_of_name name
    in
    let s = Ast.str_of_info info in
    if not (is_backward_compatible s) then begin
      was_modified := true;
      info.transfo <- Ast.Remove;
    end
  in

  let hook = { V.default_visitor with
    V.kfunc_def = (fun (k, _) def ->
      def.f_return_type +> Common.do_option remove_type_hint_tokens;
      k def;
    );
    V.kmethod_def = (fun (k, _) def ->
      def.m_return_type +> Common.do_option remove_type_hint_tokens;
      k def;
    );
    V.kparameter = (fun (k, _) p ->
      p.p_type +> Common.do_option remove_type_hint_tokens;
      k p;
    );
    V.kstmt = (fun (k, _) stmt ->
      match stmt with
      | TypedDeclaration (hint_type, lval, expr_opt, semicolon) ->
          remove_type_hint_tokens hint_type;
          k stmt
      | _ -> k stmt
    );
    V.kclass_stmt = (fun (k, _) class_stmt ->
      match class_stmt with
      | ClassVariables (modifiers, hint_type_opt, class_vars, tok) ->
          hint_type_opt +> Common.do_option remove_type_hint_tokens;
      | ClassConstants _ | Method _ | XhpDecl _ -> 
          k class_stmt
    );
  }
  in
  (V.mk_visitor hook) (Program ast);
  !was_modified

let type_hints_removal = type_hints_removal_transformation, None

(* -------------------------------------------------------------------------*)
(* to test *)
(* -------------------------------------------------------------------------*)

(* see also demos/simple_refactoring.ml *)
let simple_transfo xs = 

  let files = Lib_parsing_php.find_php_files_of_dir_or_files xs in

  Flag_parsing_php.show_parsing_error := false;
  Flag_parsing_php.verbose_lexing := false;
  files +> List.iter (fun file ->
    pr2 (spf "processing: %s" file);

    let (ast2, _stat) = Parse_php.parse file in
    let ast = Parse_php.program_of_program2 ast2 in

    let hook = { V.default_visitor with
      V.klvalue = (fun (k, _) x ->
        match Ast.untype x with
        | FunCallSimple((Name ("foo", info_foo)), (lp, args, rp)) ->
            pr2 "found match";
            
            let ii = Lib_parsing_php.ii_of_any (Lvalue x) in
            ii |> List.iter (fun info ->
              info.transfo <- Ast.Remove
            );
            info_foo.transfo <- Ast.Replace (Ast.AddStr "1");
            ()
        | _ -> k x
      );
    }
    in
    (V.mk_visitor hook) (Program ast);

    let s = Unparse_php.string_of_program2_using_tokens ast2 in
    
    let tmpfile = Common.new_temp_file "trans" ".php" in
    Common.write_file ~file:tmpfile s;
    
    let diff = Common.cmd_to_list (spf "diff -u %s %s" file tmpfile) in
    diff |> List.iter pr;
  );
  ()


(*---------------------------------------------------------------------------*)
(* the command line flags *)
(*---------------------------------------------------------------------------*)
let spatch_extra_actions () = [
  (* see also demos/simple_refactoring.ml *)
  "-simple_transfo", "<files_or_dirs>",
  Common.mk_action_n_arg (simple_transfo);

  "-send_mail_transfo", "<files_or_dirs>",
  Common.mk_action_n_arg (apply_transfo send_mail_transfo);
  "-send_mail_def_transfo", "<file>",
  Common.mk_action_n_arg (apply_transfo send_mail_def_transfo);
  "-fn_idx_transfo", "<files_or_dirs>",
  Common.mk_action_n_arg (apply_transfo fn_idx_transfo);
  "-preparer_transfo", "<files_or_dirs>",
  Common.mk_action_n_arg (apply_transfo preparer_transfo);
  "-preparer_transfo_bis", "<files_or_dirs>",
  Common.mk_action_n_arg (apply_transfo preparer_transfo_bis);
  "-event_transfo", "<files_or_dirs>",
  Common.mk_action_n_arg (apply_transfo_js event_transfo);

  "-type_hints_removal", "<files_or_dirs>",
  Common.mk_action_n_arg (fun file_or_dirs -> 
    Flag_parsing_php.type_hints_extension := true;
    apply_transfo type_hints_removal file_or_dirs);

]

(*****************************************************************************)
(* The options *)
(*****************************************************************************)

let all_actions () = 
 spatch_extra_actions()++
 Test_parsing_php.actions()++
 []

let options () = 
  [
    "-c", Arg.Set_string spatch_file, 
    " <spatch_file>";

    "-verbose", Arg.Set verbose, 
    " ";

    "-apply_patch", Arg.Set apply_patch, 
    " ";
  ] ++
  Flag_parsing_php.cmdline_flags_pp () ++
  Common.options_of_actions action (all_actions()) ++
  Common.cmdline_flags_devel () ++
  Common.cmdline_flags_verbose () ++
  Common.cmdline_flags_other () ++
  [
  "-version",   Arg.Unit (fun () -> 
    Common.pr2 (spf "sgrep_php version: %s" Config.version);
    exit 0;
  ), 
    "  guess what";

  (* this can not be factorized in Common *)
  "-date",   Arg.Unit (fun () -> 
    Common.pr2 "version: $Date: 2010/04/25 00:44:57 $";
    raise (Common.UnixExit 0)
    ), 
  "   guess what";
  ] ++
  []

(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)

let main () = 
  Common_extra.set_link ();


  let usage_msg = 
    "Usage: " ^ Common.basename Sys.argv.(0) ^ 
      " [options] <file or dir> " ^ "\n" ^ "Options are:"
  in
  (* does side effect on many global flags *)
  let args = Common.parse_options (options()) usage_msg Sys.argv in

  (* must be done after Arg.parse, because Common.profile is set by it *)
  Common.profile_code "Main total" (fun () -> 

    (match args with
   
    (* --------------------------------------------------------- *)
    (* actions, useful to debug subpart *)
    (* --------------------------------------------------------- *)
    | xs when List.mem !action (Common.action_list (all_actions())) -> 
        Common.do_action !action xs (all_actions())

    | _ when not (Common.null_string !action) -> 
        failwith ("unrecognized action or wrong params: " ^ !action)

    (* --------------------------------------------------------- *)
    (* main entry *)
    (* --------------------------------------------------------- *)
    | x::xs -> 
        main_action (x::xs)

    (* --------------------------------------------------------- *)
    (* empty entry *)
    (* --------------------------------------------------------- *)
    | [] -> 
        Common.usage usage_msg (options()); 
        failwith "too few arguments"
    )
  )

(*****************************************************************************)
let _ =
  Common.main_boilerplate (fun () -> 
      main ();
  )
