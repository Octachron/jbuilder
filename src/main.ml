open Import
open Future

let setup ?filter_out_optional_stanzas_with_missing_deps () =
  let { Jbuild_load. file_tree; tree; stanzas; packages } = Jbuild_load.load () in
  Lazy.force Context.default >>= fun ctx ->
  let rules =
    Gen_rules.gen ~context:ctx ~file_tree ~tree ~stanzas ~packages
      ?filter_out_optional_stanzas_with_missing_deps ()
  in
  let bs = Build_system.create ~file_tree ~rules in
  return (bs, stanzas, ctx)

let external_lib_deps ?log ~packages =
  Future.Scheduler.go ?log
    (setup () ~filter_out_optional_stanzas_with_missing_deps:false
     >>| fun (bs, stanzas, _) ->
     Path.Map.map
       (Build_system.all_lib_deps bs
          (List.map packages ~f:(fun pkg ->
             Path.(relative root) (pkg ^ ".install"))))
       ~f:(fun deps ->
         let internals = Jbuild_types.Stanza.lib_names stanzas in
         String_map.filter deps ~f:(fun name _ -> not (String_set.mem name internals))))

let report_error ?(map_fname=fun x->x) ppf exn ~backtrace =
  match exn with
  | Loc.Error ({ start; stop }, msg) ->
    let start_c = start.pos_cnum - start.pos_bol in
    let stop_c  = stop.pos_cnum  - start.pos_bol in
    Format.fprintf ppf
      "File \"%s\", line %d, characters %d-%d:\n\
       Error: %s\n"
      (map_fname start.pos_fname) start.pos_lnum start_c stop_c msg
  | Fatal_error msg ->
    Format.fprintf ppf "%s\n" (String.capitalize msg)
  | Findlib.Package_not_found pkg ->
    Format.fprintf ppf "Findlib package %S not found.\n" pkg
  | Code_error msg ->
    let bt = Printexc.raw_backtrace_to_string backtrace in
    Format.fprintf ppf "Internal error, please report upstream.\n\
                        Description: %s\n\
                        Backtrace:\n\
                        %s" msg bt
  | _ ->
    let s = Printexc.to_string exn in
    let bt = Printexc.raw_backtrace_to_string backtrace in
    if String.is_prefix s ~prefix:"File \"" then
      Format.fprintf ppf "%s\nBacktrace:\n%s" s bt
    else
      Format.fprintf ppf "Error: exception %s\nBacktrace:\n%s" s bt

let report_error ?map_fname ppf exn =
  match exn with
  | Build_system.Build_error.E err ->
    let module E = Build_system.Build_error in
    report_error ?map_fname ppf (E.exn err) ~backtrace:(E.backtrace err);
    if !Clflags.debug_dep_path then
      Format.fprintf ppf "Dependency path:\n    %s\n"
        (String.concat ~sep:"\n--> "
           (List.map (E.dependency_path err) ~f:Path.to_string))
  | exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    report_error ?map_fname ppf exn ~backtrace

let create_log () =
  if not (Sys.file_exists "_build") then
    Unix.mkdir "_build" 0o777;
  let oc = open_out_bin "_build/log" in
  Printf.fprintf oc "# %s\n%!"
    (String.concat (List.map (Array.to_list Sys.argv) ~f:quote_for_shell) ~sep:" ");
  oc

(* Called by the script generated by ../build.ml *)
let bootstrap () =
  let pkg = "jbuilder" in
  let main () =
    let anon s = raise (Arg.Bad (Printf.sprintf "don't know what to do with %s\n" s)) in
    Arg.parse [ "-j", Set_int Clflags.concurrency, "JOBS concurrency" ]
      anon "Usage: boot.exe [-j JOBS]\nOptions are:";
    Future.Scheduler.go ~log:(create_log ())
      (setup () >>= fun (bs, _, _) ->
       Build_system.do_build_exn bs [Path.(relative root) (pkg ^ ".install")])
  in
  try
    main ()
  with exn ->
    Format.eprintf "%a@?" (report_error ?map_fname:None) exn;
    exit 1
