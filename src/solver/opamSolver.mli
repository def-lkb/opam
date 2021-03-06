(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2013 OCamlPro                                        *)
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

(** SAT-solver for package dependencies and conflicts *)

open OpamTypes

module Action : OpamActionGraph.ACTION with type package = package
module ActionGraph : OpamActionGraph.SIG with type package = package

type solution

val empty_universe: universe

(** {2 Solver} *)

(** Convert a request to a string *)
val string_of_request: atom request -> string

(** Compute statistics about a solution *)
val stats: solution -> stats

(** Return the new packages in the solution *)
val new_packages: solution -> package_set

(** Pretty-printing of statistics *)
val string_of_stats: stats -> string

(** Is the solution empty ? *)
val solution_is_empty: solution -> bool

(** Display a solution *)
val print_solution:
  messages:(package -> string list) ->
  rewrite:(package -> package) ->
  requested:name_set ->
  solution -> unit

(** Computes an opam->cudf version map from a set of package *)
val cudf_versions_map: universe -> package_set -> int OpamPackage.Map.t

(** Creates a CUDF universe from an OPAM universe, including the given
    packages *)
val load_cudf_universe:
  ?depopts:bool -> ?build:bool -> ?test:bool -> ?doc:bool ->
  universe -> ?version_map:int package_map -> package_set -> Cudf.universe

(** Given a description of packages, return a solution preserving the
    consistency of the initial description. *)
val resolve :
  ?verbose:bool ->
  universe -> orphans:package_set -> atom request
  -> (solution, OpamCudf.conflict) result

(** Returns the graph of atomic actions (rm, inst) from a solution *)
val get_atomic_action_graph : solution -> ActionGraph.t

(** Keep only the packages that are installable. *)
val installable: universe -> package_set

(** Return the topological sort of the transitive dependency closures
    of a collection of packages.*)
val dependencies :
  depopts:bool -> ?build:bool -> ?test:bool -> ?doc:bool ->
  installed:bool ->
  ?unavailable:bool ->
  universe ->
  package_set ->
  package list

(** Same as [dependencies] but for reverse dependencies *)
val reverse_dependencies :
  depopts:bool -> ?build:bool -> ?test:bool -> ?doc:bool ->
  installed:bool ->
  ?unavailable:bool ->
  universe ->
  package_set ->
  package list

(** Dumps a cudf file containing all available packages in the given universe,
    plus version bindings (as '#v2v' comments) for the other ones. *)
val dump_universe: universe -> out_channel -> unit

(** Filters actions in a solution. Dependents of a removed actions are removed
    to keep consistency *)
val filter_solution: (package -> bool) -> solution -> solution
