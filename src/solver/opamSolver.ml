(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2014 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved.This file is distributed under the terms of the   *)
(*  GNU Lesser General Public License version 3.0 with linking            *)
(*  exception.                                                            *)
(*                                                                        *)
(*  OPAM is distributed in the hope that it will be useful, but WITHOUT   *)
(*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY    *)
(*  or FITNESS FOR A PARTICULAR PURPOSE.See the GNU General Public        *)
(*  License for more details.                                             *)
(*                                                                        *)
(**************************************************************************)

open OpamTypes
open OpamTypesBase
open OpamMisc.OP
open OpamPackage.Set.Op

let log fmt = OpamGlobals.log "SOLVER" fmt
let slog = OpamGlobals.slog

module Action = OpamActionGraph.MakeAction(OpamPackage)
module ActionGraph = OpamActionGraph.Make(Action)
type solution = OpamCudf.ActionGraph.t

let empty_universe =
  {
    u_packages = OpamPackage.Set.empty;
    u_installed = OpamPackage.Set.empty;
    u_available = OpamPackage.Set.empty;
    u_depends = OpamPackage.Map.empty;
    u_depopts = OpamPackage.Map.empty;
    u_conflicts = OpamPackage.Map.empty;
    u_action = Install OpamPackage.Name.Set.empty;
    u_installed_roots = OpamPackage.Set.empty;
    u_pinned = OpamPackage.Set.empty;
    u_base = OpamPackage.Set.empty;
  }

(* Get the optional depencies of a package *)
let depopts_of_package universe ?build ?test ?doc package =
  let opts =
    try
      filter_deps ?build ?test ?doc
        (OpamPackage.Map.find package universe.u_depopts)
    with Not_found -> Empty in
  OpamFormula.to_dnf opts

let is_installed universe (name,_) =
  OpamPackage.Set.exists (fun pkg ->
      OpamPackage.name pkg = name
    ) universe.u_installed

let find_installed universe (name, _) =
  let pkg = OpamPackage.Set.find (fun pkg ->
      OpamPackage.name pkg = name
    ) universe.u_installed in
  OpamPackage.version pkg

let is_available universe wish_remove (name, _ as c) =
  let version = find_installed universe c in
  OpamPackage.Set.exists (fun pkg ->
      OpamPackage.name pkg = name && OpamPackage.version pkg = version
    ) universe.u_available
  &&
  List.for_all (fun (n, _) -> n <> name) wish_remove

let cudf_versions_map _universe packages =
  log "cudf_versions_map";
  let pmap = OpamPackage.to_map packages in
  OpamPackage.Name.Map.fold (fun name versions acc ->
      let _, map =
        OpamPackage.Version.Set.fold
          (fun version (i,acc) ->
             let nv = OpamPackage.create name version in
             i + 1, OpamPackage.Map.add nv i acc)
          versions (1,acc) in
      map)
    pmap OpamPackage.Map.empty

let name_to_cudf name =
  Common.CudfAdd.encode (OpamPackage.Name.to_string name)

let atom2cudf _universe (version_map : int OpamPackage.Map.t) (name,cstr) =
  name_to_cudf name, match cstr with
  | None -> None
  | Some (op,v) ->
    let nv = OpamPackage.create name v in
    try
      let cv = OpamPackage.Map.find nv version_map in
      Some (op, cv)
    with Not_found ->
      (* The version for comparison doesn't exist: match to the closest
         existing version according to the direction of the comparison *)
      let all_versions =
        OpamPackage.Map.filter (fun nv _ -> OpamPackage.name nv = name)
          version_map in
      match op with
      | `Neq -> None (* Always true *)
      | `Eq -> (* Always false *)
        Some (`Eq, OpamPackage.Map.cardinal all_versions + 1)
      | (`Geq | `Gt | `Leq | `Lt) as op ->
        let sign, result_op =  match op with
          | `Geq | `Gt -> (fun x -> x), `Geq
          | `Leq | `Lt -> (fun x -> -x), `Leq in
        let rev_version_map =
          OpamPackage.Map.fold (fun nv cv acc ->
              OpamMisc.IntMap.add (sign cv) (OpamPackage.version nv) acc)
            all_versions OpamMisc.IntMap.empty in
        let map =
          OpamMisc.IntMap.filter
            (fun _ v1 -> sign (OpamPackage.Version.compare v v1) < 0)
            rev_version_map in
        if OpamMisc.IntMap.is_empty map then
          match result_op with
          | `Geq -> Some (`Gt, max 1 (OpamPackage.Map.cardinal all_versions))
          | `Leq -> Some (`Lt, 1)
        else Some (result_op, sign (fst (OpamMisc.IntMap.min_binding map)))

let opam2cudf universe ?(depopts=false) ?build ?test ?doc
    version_map package =
  let name = OpamPackage.name package in
  let depends =
    try filter_deps ?build ?test ?doc
          (OpamPackage.Map.find package universe.u_depends)
    with Not_found -> Empty in
  let depends =
    let opts = depopts_of_package universe package in
    if depopts then
      let opts = List.rev_map OpamFormula.of_conjunction opts in
      And (depends, Or(depends, OpamFormula.ors opts))
    else if universe.u_action = Remove || universe.u_action = Depends
    then depends
    else (* depopts become hard deps when they are installed *)
    let mem_installed conj = List.exists (is_installed universe) conj in
    let opts = List.filter mem_installed opts in
    let opts = List.rev_map OpamFormula.of_conjunction opts in
    And (depends, OpamFormula.ands opts) in
  let conflicts =
    try OpamPackage.Map.find package universe.u_conflicts
    with Not_found -> Empty in
  let conflicts = (* prevents install of multiple versions of the same pkg *)
    (name, None)::OpamFormula.to_conjunction conflicts in
  let installed = OpamPackage.Set.mem package universe.u_installed in
  let base = OpamPackage.Set.mem package universe.u_base in
  let reinstall = match universe.u_action with
    | Upgrade reinstall | Reinstall reinstall ->
      OpamPackage.Set.mem package reinstall
    | _                 -> false in
  let installed_root = OpamPackage.Set.mem package universe.u_installed_roots in
  let pinned_to_current_version =
    OpamPackage.Set.mem package universe.u_pinned in
  let extras =
    let e = [
      OpamCudf.s_source,
      `String (OpamPackage.Name.to_string (OpamPackage.name package));
      OpamCudf.s_source_number,
      `String (OpamPackage.Version.to_string (OpamPackage.version package));
    ] in
    let e = if installed && reinstall
      then (OpamCudf.s_reinstall, `Bool true)::e else e in
    let e = if installed_root
      then (OpamCudf.s_installed_root, `Bool true)::e else e in
    let e = if pinned_to_current_version
      then (OpamCudf.s_pinned, `Bool true)::e else e in
    e
  in
  { Cudf.default_package with
    Cudf.
    package = name_to_cudf (OpamPackage.name package);
    version = OpamPackage.Map.find package version_map;
    depends = List.rev_map (List.rev_map (atom2cudf universe version_map))
        (OpamFormula.to_cnf depends);
    conflicts = List.rev_map (atom2cudf universe version_map) conflicts;
    installed;
    keep = if base then `Keep_version else `Keep_none;
    (* was_installed: reserved for the solver; *)
    (* provides: unused atm *)
    pkg_extra = extras;
  }

(* load a cudf universe from an opam one *)
let load_cudf_universe ?depopts ?build ?test ?doc
    opam_universe ?version_map opam_packages =
  log "Load cudf universe (depopts:%b, build:%b)"
    (OpamMisc.Option.default false depopts)
    (OpamMisc.Option.default true build);
  let version_map = match version_map with
    | Some vm -> vm
    | None -> cudf_versions_map opam_universe opam_packages in
  let cudf_universe =
    let cudf_packages =
      (* Doing opam2cudf for every package is inefficient (lots of Set.mem to
         check if it is installed, etc. Optimise by gathering all info first *)
      OpamPackage.Set.fold
        (fun nv list ->
           opam2cudf opam_universe ?depopts ?build ?test ?doc version_map nv :: list)
        opam_packages [] in
    try Cudf.load_universe cudf_packages
    with Cudf.Constraint_violation s ->
      OpamGlobals.error_and_exit "Malformed CUDF universe (%s)" s
  in
  (* We can trim the universe here to get faster results, but we
     choose to keep it bigger to get more precise conflict messages. *)
  (* let universe = Algo.Depsolver.trim universe in *)
  cudf_universe

let string_of_request r =
  let to_string = OpamFormula.string_of_conjunction OpamFormula.string_of_atom in
  Printf.sprintf "install:%s remove:%s upgrade:%s"
    (to_string r.wish_install)
    (to_string r.wish_remove)
    (to_string r.wish_upgrade)

let map_action f = function
  | To_change (Some x, y) -> To_change (Some (f x), f y)
  | To_change (None, y)   -> To_change (None, f y)
  | To_delete y           -> To_delete (f y)
  | To_recompile y        -> To_recompile (f y)

let map_cause f = function
  | Upstream_changes -> Upstream_changes
  | Use l            -> Use (List.rev_map f l)
  | Required_by l    -> Required_by (List.rev_map f l)
  | Conflicts_with l -> Conflicts_with (List.rev_map f l)
  | Requested        -> Requested
  | Unknown          -> Unknown

let cudf_to_opam_graph cudf2opam cudf_graph =
  let size = OpamCudf.ActionGraph.nb_vertex cudf_graph in
  let opam_graph = ActionGraph.create ~size () in
  OpamCudf.ActionGraph.iter_vertex (fun package ->
    ActionGraph.add_vertex opam_graph (map_action cudf2opam package)
  ) cudf_graph;
  OpamCudf.ActionGraph.iter_edges (fun p1 p2 ->
    ActionGraph.add_edge opam_graph
      (map_action cudf2opam p1)
      (map_action cudf2opam p2)
  ) cudf_graph;
  opam_graph

let map_request f r =
  let f = List.rev_map f in
  { wish_install = f r.wish_install;
    wish_remove  = f r.wish_remove;
    wish_upgrade = f r.wish_upgrade;
    criteria = r.criteria }

(* Remove duplicate packages *)
(* Add upgrade constraints *)
let cleanup_request universe (req:atom request) =
  let wish_install =
    List.filter (fun (n,_) -> not (List.mem_assoc n req.wish_upgrade))
      req.wish_install in
  let wish_upgrade =
    List.rev_map (fun (n,c as pkg) ->
        if c = None
        && is_installed universe pkg
        && is_available universe req.wish_remove pkg then
          n, Some (`Geq, find_installed universe pkg)
        else
          pkg
      ) req.wish_upgrade in
  { req with wish_install; wish_upgrade }

let cycle_conflict univ cycles =
  OpamCudf.cycle_conflict univ
    (List.map
       (List.map
          (fun a -> Action.to_string (map_action OpamCudf.cudf2opam a)))
       cycles)

let resolve ?(verbose=true) universe ~orphans request =
  log "resolve request=%a" (slog string_of_request) request;
  let version_map =
    cudf_versions_map universe
      (universe.u_available ++ universe.u_installed ++ orphans) in
  let simple_universe =
    load_cudf_universe universe ~version_map
      (universe.u_available ++ universe.u_installed -- orphans) in
  let request = cleanup_request universe request in
  let cudf_request = map_request (atom2cudf universe version_map) request in
  let add_orphan_packages u =
    load_cudf_universe universe ~version_map
      (orphans ++
         (OpamPackage.Set.of_list
            (List.map OpamCudf.cudf2opam (Cudf.get_packages u)))) in
  let resolve u req =
    if OpamCudf.external_solver_available ()
    then
      try
        let resp = OpamCudf.resolve ~extern:true ~version_map u req in
        OpamCudf.to_actions add_orphan_packages u resp
      with Failure "opamSolver" ->
        OpamGlobals.error_and_exit
          "Please retry with option --use-internal-solver"
    else OpamHeuristic.resolve ~verbose ~version_map add_orphan_packages u req in
  match resolve simple_universe cudf_request with
  | Conflicts _ as c -> c
  | Success actions ->
    let all_packages =
      universe.u_available ++ orphans in
    let simple_universe =
      load_cudf_universe universe ~depopts:true ~build:false
        ~version_map all_packages in
    let complete_universe =
      load_cudf_universe universe ~depopts:true ~build:true
        ~version_map all_packages in
    try
      let atomic_actions =
        OpamCudf.atomic_actions
          ~simple_universe ~complete_universe actions in
      Success atomic_actions
    with OpamCudf.Cyclic_actions cycles ->
      cycle_conflict complete_universe cycles

let get_atomic_action_graph t =
  cudf_to_opam_graph OpamCudf.cudf2opam t

let installable universe =
  log "trim";
  let simple_universe =
    load_cudf_universe universe universe.u_available in
  let trimed_universe = Algo.Depsolver.trim simple_universe in
  Cudf.fold_packages
    (fun universe pkg -> OpamPackage.Set.add (OpamCudf.cudf2opam pkg) universe)
    OpamPackage.Set.empty
    trimed_universe

let filter_dependencies
    f_direction ~depopts ?build ?test ?doc ~installed
    ?(unavailable=false) universe packages =
  if OpamPackage.Set.is_empty packages then [] else
  let u_packages =
    packages ++
    if installed then universe.u_installed else
    if unavailable then universe.u_packages else
      universe.u_available in
  let version_map = cudf_versions_map universe u_packages in
  let cudf_universe =
    load_cudf_universe ~depopts ?build ?test ?doc universe ~version_map
      u_packages in
  let cudf_packages =
    List.rev_map (opam2cudf universe ~depopts ?build ?test ?doc version_map)
      (OpamPackage.Set.elements packages) in
  let topo_packages = f_direction cudf_universe cudf_packages in
  let result = List.rev_map OpamCudf.cudf2opam topo_packages in
  log "filter_dependencies packages=%a result=%a"
    (slog OpamPackage.Set.to_string) packages
    (slog (OpamMisc.string_of_list OpamPackage.to_string)) result;
  result

let dependencies = filter_dependencies OpamCudf.dependencies

let reverse_dependencies = filter_dependencies OpamCudf.reverse_dependencies

let new_packages sol =
  OpamCudf.ActionGraph.fold_vertex (fun action packages ->
    OpamPackage.Set.add (OpamCudf.cudf2opam (action_contents action)) packages
  ) sol OpamPackage.Set.empty

let stats sol =
  OpamCudf.ActionGraph.fold_vertex (fun action stats ->
      match action with
      | To_change (None, _) -> {stats with s_install = stats.s_install+1}
      | To_change (Some x, y) ->
        let c = Common.CudfAdd.compare x y in
        if c < 0 then {stats with s_upgrade = stats.s_upgrade+1} else
        if c > 0 then {stats with s_downgrade = stats.s_downgrade+1} else
          {stats with s_reinstall = stats.s_reinstall+1}
      | To_recompile _ -> {stats with s_reinstall = stats.s_reinstall+1}
      | To_delete _ -> {stats with s_remove = stats.s_remove+1})
    (OpamCudf.ActionGraph.reduce sol)
    { s_install=0; s_reinstall=0; s_upgrade=0; s_downgrade=0; s_remove=0 }

let string_of_stats stats =
  let utf = !OpamGlobals.utf8 in
  let stats = [
    stats.s_install;
    stats.s_reinstall;
    stats.s_upgrade;
    stats.s_downgrade;
    stats.s_remove;
  ] in
  let titles =
    List.map
      (fun a ->
         let s = OpamActionGraph.action_strings a in
         if utf then OpamActionGraph.action_color a s else s)
      [`inst;`reinst;`up;`down;`rm]
  in
  let msgs = List.filter (fun (a,_) -> a <> 0) (List.combine stats titles) in
  if utf then
    String.concat "   " @@
    List.map (fun (n,t) -> Printf.sprintf "%s %s" t (string_of_int n)) msgs
  else
    String.concat " | " @@
    List.map (fun (n,t) ->
        Printf.sprintf "%s to %s"
          (OpamGlobals.colorise `yellow (string_of_int n)) t)
      msgs

let solution_is_empty t =
  OpamCudf.ActionGraph.is_empty t

let print_solution ~messages ~rewrite ~requested t =
  let dump_cudf sfx t = match !OpamGlobals.cudf_file with
    | None -> ()
    | Some f ->
      let filename = Printf.sprintf "%s-actions%s.dot" f sfx in
      let oc = open_out filename in
      ActionGraph.Dot.output_graph oc (cudf_to_opam_graph OpamCudf.cudf2opam t);
      close_out oc
  in
  dump_cudf "-full" t;
  let t = OpamCudf.ActionGraph.reduce t in
  dump_cudf "" t;
  let causes = OpamCudf.compute_root_causes t requested in
  let actions, details =
    OpamCudf.ActionGraph.Topological.fold (fun a (actions,details) ->
        let cause =
          try OpamCudf.Map.find (action_contents a) causes
          with Not_found -> Unknown in
        let action =
          map_action (fun p -> rewrite (OpamCudf.cudf2opam p)) a
        in
        let cudf_name p = OpamPackage.name_to_string (OpamCudf.cudf2opam p) in
        let cause = string_of_cause cudf_name cause in
        let messages =
          match a with
          | To_change(_,p) | To_recompile p -> messages (OpamCudf.cudf2opam p)
          | To_delete _ -> []
        in
        action :: actions, (cause, messages) :: details
      ) t ([],[])
  in
  let actions, details = List.rev actions, List.rev details in
  let actions_str = Action.to_aligned_strings actions in
  List.iter2 (fun act (cause,messages) ->
      if cause <> "" then OpamGlobals.msg "  %-60s  [%s]\n" act cause
      else OpamGlobals.msg "  %s\n" act;
      List.iter (OpamGlobals.msg "       %s\n") messages
    ) actions_str details

let dump_universe universe oc =
  let version_map = cudf_versions_map universe universe.u_packages in
  let cudf_univ =
    load_cudf_universe ~depopts:false universe ~version_map
      universe.u_available in
  OpamCudf.dump_universe oc cudf_univ;
  (* Add explicit bindings to retrieve original versions of non-available packages *)
  OpamPackage.Map.iter (fun nv i ->
      if not (OpamPackage.Set.mem nv universe.u_available) then
        Printf.fprintf oc "#v2v:%s:%d=%s\n"
          (OpamPackage.name_to_string nv) i (OpamPackage.version_to_string nv)
    ) version_map

let filter_solution filter t =
  let t = OpamCudf.ActionGraph.copy t in
  let rec rm iter_deps v =
    if OpamCudf.ActionGraph.mem_vertex t v then (
      iter_deps (rm iter_deps) t v;
      OpamCudf.ActionGraph.remove_vertex t v
    ) in
  OpamCudf.ActionGraph.iter_vertex
    (function
      | To_delete nv as a when not (filter (OpamCudf.cudf2opam nv)) ->
        rm OpamCudf.ActionGraph.iter_pred a
      | To_change (_, nv) as a when not (filter (OpamCudf.cudf2opam nv)) ->
        rm OpamCudf.ActionGraph.iter_succ a
      | _ -> ())
    t;
  t
