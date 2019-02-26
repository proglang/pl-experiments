module Affe = Zoo.Main (struct

    let name = "Affe"

    type command = Syntax.command

    let options = []

    type environment = {
      ty : Env.t ;
      name: Syntax.Rename.env ;
      (* value: Eval.env ; *)
    }
    let add_def x ty _v env = {
      ty = Env.add x ty env.ty ;
      name = { env.name with env = Syntax.Rename.add x.name x env.name.env } ;
      (* value = Eval.add x v env.value ; *)
    }
    let add_decl ty schm env = {
      ty = Env.add_constr ty schm env.ty ;
      name = { env.name with tyenv = Syntax.Rename.add ty.name ty env.name.tyenv } ;
      (* value = env.value ; *)
    }
    let initial_environment = {
      ty = Builtin.initial_env;
      name = Builtin.initial_rename_env;
      (* value = Eval.initial_env ; *)
    }

    let read_more str = 
      let i = ref (String.length str - 1) in
      while !i >= 0 && List.mem str.[!i] [' '; '\n'; '\t'; '\r'] do decr i done ;
      !i < 1 || (str.[!i] <> ';' || str.[!i - 1] <> ';')

    let file_parser = Some (Parser.file Lexer.token)
    let toplevel_parser = Some (Parser.toplevel Lexer.token)

    let harness f =
      try f () with
      | Typing.Unif.Fail (ty1, ty2) ->
        Zoo.error ~kind:"Type error"
          "@[<2>Cannot unify types@ %a@]@ @[<2>and@ %a@]@."
          Printer.typ ty1 Printer.typ ty2
      | Typing.Kind.Fail (k1, k2) ->
        Zoo.error ~kind:"Kind error"
          "@[<2>Cannot unify kinds@ %a@]@ @[<2>and@ %a@]@."
          Printer.kind k1 Printer.kind k2
      | Multiplicity.Fail (name, u1, u2) ->
        Zoo.error ~kind:"Use error"
          "Variable %a used as %a and %a. This uses are incompatible."
          Printer.name name Printer.use u1 Printer.use u2
      | Env.Type_not_found name -> 
        Zoo.error "Unknwon type %a" Printer.name name
      | Env.Var_not_found name -> 
        Zoo.error "Unknwon variable %a" Printer.name name
    
    let exec env c =
      let c = Syntax.Rename.command env.name c in
      match c with
      | Syntax.ValueDecl {name ; expr} ->
        Zoo.print_info "@[<2>%a =@ @[%a@]@]@."
          Printer.name name  Printer.expr expr
        ;
        let _constr, typ_env, scheme =
          harness @@ fun () ->
          Typing.infer_top env.ty expr
        in
        let v = () in
        (* let v = Eval.execute env.value expr in *)
        let env = { env with ty = typ_env } in
        Zoo.print_info "@[<2>%a :@ %a@]@."
          Printer.name name  Printer.scheme scheme
          (* Printer.value v *)
          (* Printer.constrs constr *)
          (* Printer.env env.ty *)
        ;
        add_def name scheme v env
      | Syntax.ValueDef {name ; typ} ->
        let _typ_env, scheme =
          harness @@ fun () ->
          Transl.transl_type_scheme ~env:env.ty typ
        in
        Zoo.print_info "@[<2>%a :@ @[%a@]@]@."
          Printer.name name  Printer.scheme scheme
        ;
        let v = Syntax.Primitive name.name in
        add_def name scheme v env
      | Syntax.TypeDecl decl ->
        let ty_name, ty_decl, constr =
          harness @@ fun () -> 
          Transl.transl_decl ~env:env.ty decl
        in
        (* let env = { env with ty = typ_env } in *)
        Zoo.print_info "@[<2>type %a@ = %a@]@." 
          Printer.name ty_name
          Printer.kscheme ty_decl ;
        let env = add_decl ty_name ty_decl env in
        match constr with
        | None -> env
        | Some (name, decl) ->
          Zoo.print_info "@[<2>constructor %a :@ %a@]@."
            Printer.name name
            Printer.scheme decl ;        
          add_def name decl (Syntax.Constructor name) env
  end)

let () = Affe.main ()
