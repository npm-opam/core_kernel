let const c _ = c

external ignore : _ -> unit = "%ignore" (* this has the same behavior as [Pervasives.ignore] *)

let non f x = not (f x)

let forever f =
  let rec forever () =
    f ();
    forever ()
  in
  try forever ()
  with e -> e

external id : 'a -> 'a = "%identity"

external ( |! ) : 'a -> ( 'a -> 'b) -> 'b = "%revapply"
external ( |> ) : 'a -> ( 'a -> 'b) -> 'b = "%revapply"

let%test _ = 1 |> fun x -> x = 1
let%test _ = 1 |> fun x -> x + 1 |> fun y -> y = 2

(* The typical use case for these functions is to pass in functional arguments and get
   functions as a result. *)
let compose f g x = f (g x)

let flip f x y = f y x

let rec apply_n_times ~n f x =
  if n <= 0
  then x
  else apply_n_times ~n:(n - 1) f (f x)

let%test _ = 0  = apply_n_times ~n:0 (fun _ -> assert false) 0
let%test _ = 0  = apply_n_times ~n:(-3) (fun _ -> assert false) 0
let%test _ = 10 = apply_n_times ~n:10 ((+) 1) 0
