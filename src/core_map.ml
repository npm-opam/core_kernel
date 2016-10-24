open Sexplib
open Sexplib.Conv
open Core_map_intf
open With_return

module Symmetric_diff_element = Symmetric_diff_element

module List = Core_list

open Int_replace_polymorphic_compare

module Tree0 = struct

  type ('k, 'v) t =
  | Empty
  | Leaf of 'k * 'v
  | Node of ('k, 'v) t * 'k * 'v * ('k, 'v) t * int

  type ('k, 'v) tree = ('k, 'v) t

  let height = function
    | Empty -> 0
    | Leaf _ -> 1
    | Node(_,_,_,_,h) -> h
  ;;

  let invariants =
    let in_range lower upper compare_key k =
      (match lower with
       | None -> true
       | Some lower -> compare_key lower k < 0
      )
      && (match upper with
        | None -> true
        | Some upper -> compare_key k upper < 0
      )
    in
    let rec loop lower upper compare_key t =
      match t with
      | Empty -> true
      | Leaf (k, _) -> in_range lower upper compare_key k
      | Node (l, k, _, r, h) ->
        let hl = height l and hr = height r in
        abs (hl - hr) <= 2
        && h = (max hl hr) + 1
        && in_range lower upper compare_key k
        && loop lower (Some k) compare_key l
        && loop (Some k) upper compare_key r
    in
    fun t ~compare_key ->
      loop None None compare_key t
  ;;

  let create l x d r =
    let hl = height l and hr = height r in
    if hl = 0 && hr = 0 then
      Leaf (x, d)
    else
      Node(l, x, d, r, (if hl >= hr then hl + 1 else hr + 1))
  ;;

  let singleton key data = Leaf (key, data)

  (* [init_for_bin_prot] makes the assumption that [f] is called with increasing indexes
     from [0] to [len - 1]. *)
  let init_unsafe ~len ~f =
    let rec loop n ~f i : (_, _) t =
      match n with
      | 0 -> Empty
      | 1 ->
        let k,v = f i in
        Leaf (k, v)
      | 2 ->
        let kl,vl = f  i      in
        let k ,v  = f (i + 1) in
        Node (Leaf (kl, vl), k, v, Empty, 2)
      | 3 ->
        let kl,vl = f  i      in
        let k,v   = f (i + 1) in
        let kr,vr = f (i + 2) in
        Node (Leaf (kl, vl), k, v, Leaf (kr, vr), 2)
      | n ->
        let left_length = n lsr 1 in
        let right_length = n - left_length - 1 in
        let left  = loop left_length ~f i in
        let k, v  = f (i + left_length) in
        let right = loop right_length ~f (i + left_length + 1) in
        create left k v right
    in
    loop len ~f 0

  let%test _ =
    let map = init_unsafe ~len:20 ~f:(fun x -> x,x) in
    let compare_key x y =
      if x = y      then 0
      else if x < y then -1
      else               1
    in
    invariants map ~compare_key

  let of_sorted_array_unchecked array ~compare_key =
    let array_length = Array.length array in
    let next =
      if array_length < 2
         || let k0, _ = array.(0) in
         let k1, _ = array.(1) in
         compare_key k0 k1 < 0
      then
        (fun i -> array.(i))
      else
        (fun i -> array.(array_length - 1 - i))
    in
    (init_unsafe ~len:array_length ~f:next, array_length)

  let of_sorted_array array ~compare_key =
    match array with
    | [||] | [|_|] -> Result.Ok (of_sorted_array_unchecked array ~compare_key)
    | _ ->
      with_return (fun r ->
        let increasing =
          match compare_key (fst array.(0)) (fst array.(1)) with
          | 0 -> r.return (Or_error.error_string "of_sorted_array: duplicated elements")
          | i -> i < 0
        in
        for i = 1 to Array.length array - 2 do
          match compare_key (fst array.(i)) (fst array.(i+1)) with
          | 0 -> r.return (Or_error.error_string "of_sorted_array: duplicated elements")
          | i ->
            if Pervasives.(<>) (i < 0) increasing then
              r.return (Or_error.error_string "of_sorted_array: elements are not ordered")
        done;
        Result.Ok (of_sorted_array_unchecked array ~compare_key)
      )

  let bal l x d r =
    let hl = height l in
    let hr = height r in
    if hl > hr + 2 then begin
      match l with
        Empty -> invalid_arg "Map.bal"
      | Leaf _ -> assert false (* height(Leaf) = 1 && 1 is not larger than hr + 2 *)
      | Node(ll, lv, ld, lr, _) ->
        if height ll >= height lr then
          create ll lv ld (create lr x d r)
        else begin
          match lr with
            Empty -> invalid_arg "Map.bal"
          | Leaf (lrv, lrd) ->
            create (create ll lv ld Empty) lrv lrd (create Empty x d r)
          | Node(lrl, lrv, lrd, lrr, _)->
            create (create ll lv ld lrl) lrv lrd (create lrr x d r)
        end
    end else if hr > hl + 2 then begin
      match r with
        Empty -> invalid_arg "Map.bal"
      | Leaf _ -> assert false (* height(Leaf) = 1 && 1 is not larger than hl + 2 *)
      | Node(rl, rv, rd, rr, _) ->
        if height rr >= height rl then
          create (create l x d rl) rv rd rr
        else begin
          match rl with
            Empty -> invalid_arg "Map.bal"
          | Leaf (rlv, rld) ->
            create (create l x d Empty) rlv rld (create Empty rv rd rr)
          | Node(rll, rlv, rld, rlr, _) ->
            create (create l x d rll) rlv rld (create rlr rv rd rr)
        end
    end
    else create l x d r
  ;;

  let empty = Empty

  let is_empty = function Empty -> true | _ -> false

  let rec add t ~length ~key:x ~data ~compare_key =
    match t with
    | Empty -> (Leaf (x, data), length + 1)
    | Leaf(v, d) ->
      let c = compare_key x v in
      if c = 0 then
        (Leaf(x, data), length)
      else if c < 0 then
        (Node(Leaf(x, data), v, d, Empty, 2), length + 1)
      else
        (Node(Empty, v, d, Leaf(x, data), 2), length + 1)
    | Node(l, v, d, r, h) ->
      let c = compare_key x v in
      if c = 0 then
        (Node(l, x, data, r, h), length)
      else if c < 0 then
        let l, length = add ~length ~key:x ~data l ~compare_key in
        (bal l v d r, length)
      else
        let r, length = add ~length ~key:x ~data r ~compare_key in
        (bal l v d r, length)
  ;;

  let add' t key data ~compare_key = fst (add t ~length:0 ~key ~data ~compare_key)

  (* Like [bal] but allows any difference in height between [l] and [r]. *)
  let rec join l k d r ~compare_key =
    match l, r with
    | Empty, _ -> add' r k d ~compare_key
    | _, Empty -> add' l k d ~compare_key
    | Leaf(lk, ld), _ -> add' (add' r k d ~compare_key) lk ld ~compare_key
    | _, Leaf(rk, rd) -> add' (add' l k d ~compare_key) rk rd ~compare_key
    | Node(ll, lk, ld, lr, lh), Node(rl, rk, rd, rr, rh) ->
      if lh > rh + 2
      (* height lr <= height (join lr k d r) <= height lr + 1 *)
      then bal ll lk ld (join lr k d r ~compare_key)
      else if rh > lh + 2
      then bal (join l k d rl ~compare_key) rk rd rr
      else create l k d r
  ;;

  let rec split t x ~compare_key =
    match t with
    | Empty -> (Empty, None, Empty)
    | Leaf(k, d) ->
      let cmp = compare_key x k in
      if cmp = 0 then (Empty, Some (k, d), Empty)
      else if cmp < 0 then (Empty, None, t)
      else (t, None, Empty)
    | Node(l, k, d, r, _) ->
      let cmp = compare_key x k in
      if cmp = 0 then (l, Some (k, d), r)
      else if cmp < 0 then
        let ll, maybe, lr = split l x ~compare_key in
        (ll, maybe, join lr k d r ~compare_key)
      else
        let rl, maybe, rr = split r x ~compare_key in
        (join l k d rl ~compare_key, maybe, rr)
  ;;

  let rec find t x ~compare_key =
    match t with
    | Empty -> None
    | Leaf (v, d) -> if compare_key x v = 0 then Some d else None
    | Node(l, v, d, r, _) ->
      let c = compare_key x v in
      if c = 0 then Some d
      else find (if c < 0 then l else r) x ~compare_key
  ;;

  let add_multi t ~length ~key ~data ~compare_key =
    let data = data :: Option.value (find t key ~compare_key) ~default:[] in
    add ~length ~key ~data t ~compare_key
  ;;

  let find_exn t x ~compare_key =
    match find t x ~compare_key with
    | Some data -> data
    | None ->
      raise Not_found
  ;;

  let mem t x ~compare_key = Option.is_some (find t x ~compare_key)

  let rec min_elt = function
    | Empty -> None
    | Leaf (k, d) -> Some (k, d)
    | Node (Empty, k, d, _, _) -> Some (k, d)
    | Node (l, _, _, _, _) -> min_elt l
  ;;

  exception Map_min_elt_exn_of_empty_map [@@deriving sexp]
  exception Map_max_elt_exn_of_empty_map [@@deriving sexp]

  let min_elt_exn t =
    match min_elt t with
    | None -> raise Map_min_elt_exn_of_empty_map
    | Some v -> v
  ;;

  let rec max_elt = function
    | Empty -> None
    | Leaf (k, d) -> Some (k, d)
    | Node (_, k, d, Empty, _) -> Some (k, d)
    | Node (_, _, _, r, _) -> max_elt r
  ;;
  let max_elt_exn t =
    match max_elt t with
    | None -> raise Map_max_elt_exn_of_empty_map
    | Some v -> v
  ;;

  let rec remove_min_elt t =
    match t with
      Empty -> invalid_arg "Map.remove_min_elt"
    | Leaf _ -> Empty
    | Node(Empty, _, _, r, _) -> r
    | Node(l, x, d, r, _) -> bal (remove_min_elt l) x d r

  (* assumes that min <= max in the ordering given by compare_key *)
  let rec fold_range_inclusive t ~min ~max ~init ~f ~compare_key =
    match t with
    | Empty -> init
    | Leaf (k, d) ->
      if compare_key k min < 0 || compare_key k max > 0 then
        (* k < min || k > max *)
        init
      else
        f ~key:k ~data:d init
    | Node (l, k, d, r, _) ->
      let c_min = compare_key k min in
      if c_min < 0 then
        (* if k < min, then this node and its left branch are outside our range *)
        fold_range_inclusive r ~min ~max ~init ~f ~compare_key
      else if c_min = 0 then
        (* if k = min, then this node's left branch is outside our range *)
        fold_range_inclusive r ~min ~max ~init:(f ~key:k ~data:d init) ~f ~compare_key
      else (* k > min *)
        begin
          let z = fold_range_inclusive l ~min ~max ~init ~f ~compare_key in
          let c_max = compare_key k max in
          (* if k > max, we're done *)
          if c_max > 0 then z
          else
            let z = f ~key:k ~data:d z in
            (* if k = max, then we fold in this one last value and we're done *)
            if c_max = 0 then z
            else fold_range_inclusive r ~min ~max ~init:z ~f ~compare_key
        end
  ;;

  let range_to_alist t ~min ~max ~compare_key =
    List.rev
      (fold_range_inclusive t ~min ~max ~init:[] ~f:(fun ~key ~data l -> (key,data)::l)
         ~compare_key)
  ;;

  let concat t1 t2 =
    match (t1, t2) with
    | (Empty, t) -> t
    | (t, Empty) -> t
    | (_, _) ->
      let (x, d) = min_elt_exn t2 in
      bal t1 x d (remove_min_elt t2)
  ;;

  let rec remove t x ~length ~compare_key =
    match t with
    | Empty -> (Empty, length)
    | Leaf (v, _) ->
      if compare_key x v = 0 then
        (Empty, length - 1)
      else (t, length)
    | Node(l, v, d, r, _) ->
      let c = compare_key x v in
      if c = 0 then
        (concat l r, length - 1)
      else if c < 0 then
        let l, length = remove l x ~length ~compare_key in
        (bal l v d r, length)
      else
        let r, length = remove r x ~length ~compare_key in
        (bal l v d r, length)
  ;;

  (* Use exception to avoid tree-rebuild in no-op case *)
  exception Change_no_op

  let change t key ~f ~length ~compare_key =
    let rec change_core t key f =
      match t with
      | Empty ->
        begin match (f None) with
          | None -> raise Change_no_op (* equivalent to returning: Empty *)
          | Some data -> (Leaf(key, data), length + 1)
        end
      | Leaf(v, d) ->
        let c = compare_key key v in
        if c = 0 then
          match f (Some d) with
          | None -> (Empty, length - 1)
          | Some d' -> (Leaf(v, d'), length)
        else if c < 0 then
          let l, length = change_core Empty key f in
          (bal l v d Empty, length)
        else
          let r, length = change_core Empty key f in
          (bal Empty v d r, length)
      | Node(l, v, d, r, h) ->
        let c = compare_key key v in
        if c = 0 then
          begin match (f (Some d)) with
            | None -> (concat l r, length - 1)
            | Some data -> (Node(l, key, data, r, h), length)
          end
        else
          if c < 0 then
            let l, length = change_core l key f in
            (bal l v d r, length)
          else
            let r, length = change_core r key f in
            (bal l v d r, length)
    in
    try change_core t key f with Change_no_op -> (t, length)
  ;;

  let remove_multi t key ~length ~compare_key =
    change t key ~length ~compare_key ~f:(function
      | None | Some ([] | [_])                   -> None
      | Some (_ :: ((_ :: _) as non_empty_tail)) -> Some non_empty_tail)
  ;;

  let rec iteri t ~f =
    match t with
    | Empty -> ()
    | Leaf(v, d) -> f ~key:v ~data:d
    | Node(l, v, d, r, _) -> iteri ~f l; f ~key:v ~data:d; iteri ~f r
  ;;

  let rec iter_keys t ~f =
    match t with
    | Empty -> ()
    | Leaf(v, _) -> f v
    | Node(l, v, _, r, _) -> iter_keys ~f l; f v; iter_keys ~f r
  ;;

  let rec map t ~f =
    match t with
    | Empty               -> Empty
    | Leaf(v, d)          -> Leaf(v, f d)
    | Node(l, v, d, r, h) ->
        let l' = map ~f l in
        let d' = f d in
        let r' = map ~f r in
        Node(l', v, d', r', h)
  ;;

  let rec mapi t ~f =
    match t with
    | Empty               -> Empty
    | Leaf(v, d)          -> Leaf(v, f ~key:v ~data:d)
    | Node(l, v, d, r, h) ->
        let l' = mapi ~f l in
        let d' = f ~key:v ~data:d in
        let r' = mapi ~f r in
        Node(l', v, d', r', h)
  ;;

  let rec fold t ~init:accu ~f =
    match t with
    | Empty -> accu
    | Leaf(v, d) -> f ~key:v ~data:d accu
    | Node(l, v, d, r, _) -> fold ~f r ~init:(f ~key:v ~data:d (fold ~f l ~init:accu))
  ;;

  let rec fold_right t ~init:accu ~f =
    match t with
    | Empty -> accu
    | Leaf(v, d) -> f ~key:v ~data:d accu
    | Node(l, v, d, r, _) ->
        fold_right ~f l ~init:(f ~key:v ~data:d (fold_right ~f r ~init:accu))
  ;;

  let filteri t ~f ~compare_key =
    fold ~init:(Empty, 0) t ~f:(fun ~key ~data (accu, length) ->
      if f ~key ~data
      then add ~length ~key ~data accu ~compare_key
      else (accu, length))
  ;;

  let filter_keys t ~f ~compare_key =
    fold ~init:(Empty, 0) t ~f:(fun ~key ~data (accu, length) ->
      if f key
      then add ~length ~key ~data accu ~compare_key
      else (accu, length))
  ;;

  let filter_map t ~f ~compare_key =
    fold ~init:(Empty, 0) t ~f:(fun ~key ~data (accu, length) ->
      match f data with
      | None -> (accu, length)
      | Some b -> add ~length ~key ~data:b accu ~compare_key)
  ;;

  let filter_mapi t ~f ~compare_key =
    fold ~init:(Empty, 0) t ~f:(fun ~key ~data (accu, length) ->
      match f ~key ~data with
      | None -> (accu, length)
      | Some b -> add ~length ~key ~data:b accu ~compare_key)
  ;;

  let partition_mapi t ~f ~compare_key =
    fold t ~init:((Empty, 0), (Empty, 0)) ~f:(fun ~key ~data (pair1, pair2) ->
      match f ~key ~data with
      | `Fst x ->
        let t, length = pair1 in
        (add t ~key ~data:x ~compare_key ~length, pair2)
      | `Snd y ->
        let t, length = pair2 in
        (pair1, add t ~key ~data:y ~compare_key ~length))
  ;;

  let partition_map t ~f ~compare_key =
    partition_mapi t ~compare_key ~f:(fun ~key:_ ~data -> f data)
  ;;

  let partitioni_tf t ~f ~compare_key =
    partition_mapi t ~compare_key ~f:(fun ~key ~data ->
      if f ~key ~data
      then `Fst data
      else `Snd data)
  ;;

  let partition_tf t ~f ~compare_key =
    partition_mapi t ~compare_key ~f:(fun ~key:_ ~data ->
      if f data
      then `Fst data
      else `Snd data)
  ;;

  module Enum = struct
    type increasing
    type decreasing

    type ('k, 'v, 'direction) t =
    | End
    | More of 'k * 'v * ('k, 'v) tree * ('k, 'v, 'direction) t

    let rec cons t (e : (_, _, increasing) t) : (_, _, increasing) t =
      match t with
      | Empty -> e
      | Leaf(v, d) -> More(v, d, Empty, e)
      | Node(l, v, d, r, _) -> cons l (More(v, d, r, e))
    ;;

    let rec cons_right t (e : (_, _, decreasing) t) : (_, _, decreasing) t  =
      match t with
      | Empty -> e
      | Leaf(v, d) -> More(v, d, Empty, e)
      | Node(l, v, d, r, _) -> cons_right r (More(v, d, l, e))
    ;;

    let of_tree tree : (_, _, increasing) t  = cons tree End
    ;;

    let of_tree_right tree : (_, _, decreasing) t = cons_right tree End
    ;;

    let starting_at_increasing t key compare : (_, _, increasing) t =
      let rec loop t e =
        match t with
        | Empty -> e
        | Leaf(v, d) -> loop (Node(Empty, v, d, Empty, 1)) e
        | Node(_, v, _, r, _) when compare v key < 0 -> loop r e
        | Node(l, v, d, r, _) -> loop l (More(v, d, r, e))
      in
      loop t End
    ;;

    let starting_at_decreasing t key compare : (_, _, decreasing) t =
      let rec loop t e =
        match t with
        | Empty -> e
        | Leaf(v, d) -> loop (Node(Empty, v, d, Empty, 1)) e
        | Node(l, v, _, _, _) when compare v key > 0 -> loop l e
        | Node(l, v, d, r, _) -> loop r (More(v, d, l, e))
      in
      loop t End
    ;;

    let compare compare_key compare_data t1 t2 =
      let rec loop t1 t2 =
        match t1, t2 with
        | (End, End) -> 0
        | (End, _)  -> -1
        | (_, End) -> 1
        | (More (v1, d1, r1, e1), More (v2, d2, r2, e2)) ->
          let c = compare_key v1 v2 in
          if c <> 0 then c else
            let c = compare_data d1 d2 in
            if c <> 0 then c else loop (cons r1 e1) (cons r2 e2)
      in
      loop t1 t2
    ;;

    let equal compare_key data_equal t1 t2 =
      let rec loop t1 t2 =
        match t1, t2 with
        | (End, End) -> true
        | (End, _) | (_, End) -> false
        | (More (v1, d1, r1, e1), More (v2, d2, r2, e2)) ->
          compare_key v1 v2 = 0
          && data_equal d1 d2
          && loop (cons r1 e1) (cons r2 e2)
      in
      loop t1 t2
    ;;

    let rec fold ~init ~f = function
      | End -> init
      | More (key, data, tree, enum) ->
        let next = f ~key ~data init in
        fold (cons tree enum) ~init:next ~f
    ;;

    let fold2 compare_key t1 t2 ~init ~f =
      let rec loop t1 t2 curr =
        match t1, t2 with
        | End, End -> curr
        | End, _   ->
          fold t2 ~init:curr ~f:(fun ~key ~data acc -> f ~key ~data:(`Right data) acc)
        | _  , End ->
          fold t1 ~init:curr ~f:(fun ~key ~data acc -> f ~key ~data:(`Left data) acc)
        | More (k1, v1, tree1, enum1), More (k2, v2, tree2, enum2) ->
          let compare_result = compare_key k1 k2 in
          if compare_result = 0 then begin
            let next = f ~key:k1 ~data:(`Both (v1, v2)) curr in
            loop (cons tree1 enum1) (cons tree2 enum2) next
          end else if compare_result < 0 then begin
            let next = f ~key:k1 ~data:(`Left v1) curr in
            loop (cons tree1 enum1) t2 next
          end else begin
            let next = f ~key:k2 ~data:(`Right v2) curr in
            loop t1 (cons tree2 enum2) next
          end
      in
      loop t1 t2 init
    ;;

    let symmetric_diff t1 t2 ~compare_key ~data_equal =
      let step state =
        match state with
        | End, End ->
          Sequence.Step.Done
        | End, More (key, data, tree, enum) ->
          Sequence.Step.Yield ((key, `Right data), (End, cons tree enum))
        | More (key, data, tree, enum), End ->
          Sequence.Step.Yield ((key, `Left data), (cons tree enum, End))
        | (More (k1, v1, tree1, enum1) as left), (More (k2, v2, tree2, enum2) as right) ->
          let compare_result = compare_key k1 k2 in
          if compare_result = 0 then begin
            let next_state =
              if Pervasives.(==) tree1 tree2
              then (enum1, enum2)
              else (cons tree1 enum1, cons tree2 enum2)
            in
            if data_equal v1 v2
            then Sequence.Step.Skip next_state
            else Sequence.Step.Yield ((k1, `Unequal (v1, v2)), next_state)
          end else if compare_result < 0 then begin
            Sequence.Step.Yield ((k1, `Left v1), (cons tree1 enum1, right))
          end else begin
            Sequence.Step.Yield ((k2, `Right v2), (left, (cons tree2 enum2)))
          end
      in
      Sequence.unfold_step ~init:(of_tree t1, of_tree t2) ~f:step
    ;;
  end

  let to_sequence_increasing comparator ~from_key t =
    let next enum =
      match enum with
      | Enum.End -> Sequence.Step.Done
      | Enum.More(k,v,t,e) -> Sequence.Step.Yield((k,v), Enum.cons t e)
    in
    let init =
      match from_key with
      | None -> Enum.of_tree t
      | Some key -> Enum.starting_at_increasing t key comparator.Comparator.compare
    in
    Sequence.unfold_step ~init ~f:next
  ;;

  let to_sequence_decreasing comparator ~from_key t =
    let next enum =
      match enum with
      | Enum.End -> Sequence.Step.Done
      | Enum.More(k,v,t,e) -> Sequence.Step.Yield((k,v), Enum.cons_right t e)
    in
    let init =
      match from_key with
      | None -> Enum.of_tree_right t
      | Some key -> Enum.starting_at_decreasing t key comparator.Comparator.compare
    in
    Sequence.unfold_step ~init ~f:next
  ;;

  let to_sequence comparator ?(order=`Increasing_key) ?keys_greater_or_equal_to
        ?keys_less_or_equal_to t =
    let inclusive_bound side t bound =
      let compare_key = comparator.Comparator.compare in
      let l, maybe, r = split t bound ~compare_key in
      let t = side (l, r) in
      match maybe with
      | None -> t
      | Some (key, data) -> add' t key data ~compare_key
    in
    match order with
    | `Increasing_key ->
      let t = Option.fold keys_less_or_equal_to ~init:t ~f:(inclusive_bound fst) in
      to_sequence_increasing comparator ~from_key:keys_greater_or_equal_to t
    | `Decreasing_key ->
      let t = Option.fold keys_greater_or_equal_to ~init:t ~f:(inclusive_bound snd) in
      to_sequence_decreasing comparator ~from_key:keys_less_or_equal_to t
  ;;

  let compare compare_key compare_data t1 t2 =
    Enum.compare compare_key compare_data (Enum.of_tree t1) (Enum.of_tree t2)
  ;;

  let equal compare_key compare_data t1 t2 =
    Enum.equal compare_key compare_data (Enum.of_tree t1) (Enum.of_tree t2)
  ;;

  let iter2 t1 t2 ~f ~compare_key =
    Enum.fold2 compare_key (Enum.of_tree t1) (Enum.of_tree t2)
      ~init:()
      ~f:(fun ~key ~data () -> f ~key ~data)
  ;;

  let fold2 t1 t2 ~init ~f ~compare_key =
    Enum.fold2 compare_key (Enum.of_tree t1) (Enum.of_tree t2) ~f ~init
  ;;

  let symmetric_diff = Enum.symmetric_diff

  let rec length = function
    | Empty -> 0
    | Leaf _ -> 1
    | Node (l, _, _, r, _) -> length l + length r + 1
  ;;

  let of_alist_fold alist ~init ~f ~compare_key =
    List.fold alist ~init:(empty, 0)
      ~f:(fun (accum, length) (key, data) ->
        let prev_data =
          match find accum key ~compare_key with
          | None -> init
          | Some prev -> prev
        in
        let data = f prev_data data in
        add accum ~length ~key ~data ~compare_key)
  ;;

  let of_alist_reduce alist ~f ~compare_key =
    List.fold alist ~init:(empty, 0)
      ~f:(fun (accum, length) (key, data) ->
        let new_data =
          match find accum key ~compare_key with
          | None -> data
          | Some prev -> f prev data
        in
        add accum ~length ~key ~data:new_data ~compare_key)
  ;;

  let keys t = fold_right ~f:(fun ~key ~data:_ list -> key::list) t ~init:[]
  let data t = fold_right ~f:(fun ~key:_ ~data list -> data::list) t ~init:[]

  let of_alist alist ~compare_key =
    with_return (fun r ->
      let map =
        List.fold alist ~init:(empty, 0) ~f:(fun (t, length) (key,data) ->
          if mem t key ~compare_key then r.return (`Duplicate_key key)
          else add ~length ~key ~data t ~compare_key)
      in
      `Ok map)

  let for_all t ~f =
    with_return (fun r ->
      iteri t ~f:(fun ~key:_ ~data -> if not (f data) then r.return false);
      true)

  let for_alli t ~f =
    with_return (fun r ->
      iteri t ~f:(fun ~key ~data -> if not (f ~key ~data) then r.return false);
      true)

  let exists t ~f =
    with_return (fun r ->
      iteri t ~f:(fun ~key:_ ~data -> if f data then r.return true);
      false)

  let existsi t ~f =
    with_return (fun r ->
      iteri t ~f:(fun ~key ~data -> if f ~key ~data then r.return true);
      false)

  let count t ~f =
    fold t ~init:0 ~f:(fun ~key:_ ~data acc -> if f data then acc + 1 else acc)

  let counti t ~f =
    fold t ~init:0 ~f:(fun ~key ~data acc -> if f ~key ~data then acc + 1 else acc)

  let of_alist_or_error alist ~comparator =
    match of_alist alist ~compare_key:comparator.Comparator.compare with
    | `Ok x -> Result.Ok x
    | `Duplicate_key key ->
      let sexp_of_key = comparator.Comparator.sexp_of_t in
      Or_error.error "Map.of_alist_exn: duplicate key" key [%sexp_of: key]
  ;;

  let of_alist_exn alist ~comparator =
    match of_alist_or_error alist ~comparator with
    | Result.Ok x -> x
    | Result.Error e -> Error.raise e
  ;;

  let of_alist_multi alist ~compare_key =
    let alist = List.rev alist in
    of_alist_fold alist ~init:[] ~f:(fun l x -> x :: l) ~compare_key
  ;;

  let to_alist ?(key_order = `Increasing) t =
    match key_order with
    | `Increasing -> fold_right t ~init:[] ~f:(fun ~key ~data x -> (key, data) :: x)
    | `Decreasing -> fold       t ~init:[] ~f:(fun ~key ~data x -> (key, data) :: x)
  ;;

  let merge t1 t2 ~f ~compare_key =
    let elts = Core_array.create ~len:(length t1 + length t2) (Obj.magic None) in
    let i = ref 0 in
    iter2 t1 t2 ~compare_key ~f:(fun ~key ~data:values ->
      match f ~key values with
      | Some value -> elts.(!i) <- (key, value); incr i
      | None -> ());
    (* [Core_array.truncate] raises if [len = 0] *)
    if !i = 0 then
      (empty, 0)
    else begin
      Core_array.truncate elts ~len:!i;
      of_sorted_array_unchecked ~compare_key elts
    end
  ;;

  module Closest_key_impl = struct
    (* [marker] and [repackage] allow us to create "logical" options without actually
       allocating any options. Passing [Found key value] to a function is equivalent to
       passing [Some (key, value)]; passing [Missing () ()] is equivalent to passing
       [None]. *)
    type ('k, 'v, 'k_opt, 'v_opt) marker =
      | Missing : ('k, 'v, unit, unit) marker
      | Found : ('k, 'v, 'k, 'v) marker

    let repackage (type k) (type v) (type k_opt) (type v_opt)
          (marker : (k, v, k_opt, v_opt) marker) (k : k_opt) (v : v_opt)
      : (k * v) option =
      match marker with
      | Missing -> None
      | Found -> Some (k, v)
    ;;

    (* The type signature is explicit here to allow polymorphic recursion. *)
    let rec loop
      :  'k 'v 'k_opt 'v_opt.
         ('k, 'v) tree
      -> [ `Greater_or_equal_to
         | `Greater_than
         | `Less_or_equal_to
         | `Less_than
         ]
      -> 'k -> compare_key:('k -> 'k -> int)
      -> ('k, 'v, 'k_opt, 'v_opt) marker -> 'k_opt -> 'v_opt
      -> ('k * 'v) option
      = fun t dir k ~compare_key found_marker found_key found_value ->
        match t with
        | Empty ->
          repackage found_marker found_key found_value
        | Leaf (k', v') ->
          let c = compare_key k' k in
          if
            match dir with
            | `Greater_or_equal_to -> c >= 0
            | `Greater_than -> c > 0
            | `Less_or_equal_to -> c <= 0
            | `Less_than -> c < 0
          then
            Some (k', v')
          else
            repackage found_marker found_key found_value
        | Node (l, k', v', r, _) ->
          let c = compare_key k' k in
          if c = 0 then begin
            (* This is a base case (no recursive call). *)
            match dir with
            | `Greater_or_equal_to | `Less_or_equal_to ->
              Some (k', v')
            | `Greater_than ->
              if is_empty r then
                repackage found_marker found_key found_value
              else
                min_elt r
            | `Less_than ->
              if is_empty l then
                repackage found_marker found_key found_value
              else
                max_elt l
          end else begin
            (* We are guaranteed here that k' <> k. *)
            (* This is the only recursive case. *)
            match dir with
            | `Greater_or_equal_to | `Greater_than ->
              if c > 0
              then loop l dir k ~compare_key Found k' v'
              else loop r dir k ~compare_key found_marker found_key found_value
            | `Less_or_equal_to | `Less_than ->
              if c < 0
              then loop r dir k ~compare_key Found k' v'
              else loop l dir k ~compare_key found_marker found_key found_value
          end
    ;;

    let closest_key t dir k ~compare_key =
      loop t dir k ~compare_key Missing () ()
    ;;
  end
  let closest_key = Closest_key_impl.closest_key

  let rec rank t k ~compare_key =
    match t with
    | Empty -> None
    | Leaf (k', _) -> if compare_key k' k = 0 then Some 0 else None
    | Node (l, k', _, r, _) ->
      let c = compare_key k' k in
      if c = 0
      then Some (length l)
      else if c > 0
      then rank l k ~compare_key
      else Option.map (rank r k ~compare_key) ~f:(fun rank -> rank + 1 + (length l))
  ;;

  (* this could be implemented using [Sequence] interface but the following implementation
     allocates only 2 words and doesn't require write-barrier *)
  let rec nth' num_to_search = function
    | Empty       -> None
    | Leaf (k, v) ->
      if !num_to_search = 0
      then Some (k, v)
      else begin
        decr num_to_search;
        None
      end
    | Node (l, k, v, r, _) ->
      match nth' num_to_search l with
      | (Some _) as some -> some
      | None             ->
        if !num_to_search = 0
        then Some (k, v)
        else begin
          decr num_to_search;
          nth' num_to_search r
        end

  let nth t n = nth' (ref n) t
  ;;

  let t_of_sexp key_of_sexp value_of_sexp sexp ~comparator =
    let alist = [%of_sexp: (key * value) list] sexp in
    of_alist_exn alist ~comparator
  ;;

  let sexp_of_t sexp_of_key sexp_of_value t =
    let f ~key ~data acc = Sexp.List [sexp_of_key key; sexp_of_value data] :: acc in
    Sexp.List (fold_right ~f t ~init:[])
  ;;
end

type ('k, 'v, 'comparator) t =
  { (* [comparator] is the first field so that polymorphic comparisons fail on a map due
       to the functional value in the comparator. *)
    comparator : ('k, 'comparator) Comparator.t;
    tree : ('k, 'v) Tree0.t;
    length : int;
  }

let comparator t = t.comparator

type ('k, 'v, 'comparator) tree = ('k, 'v) Tree0.t

let compare_key t = t.comparator.Comparator.compare

let like {tree = _; length = _; comparator} (tree, length) = {tree; length; comparator}
let like2 x (y,z) = like x y, like x z
let with_same_length { tree = _; comparator; length } tree =
  { tree; comparator; length }

let of_tree ~comparator tree = { tree; comparator; length = Tree0.length tree}

module Accessors_without_quickcheckable = struct
  let to_tree t = t.tree
  let invariants t = Tree0.invariants t.tree ~compare_key:(compare_key t)
  let is_empty t = Tree0.is_empty t.tree
  let length t = t.length
  let add t ~key ~data =
    like t (Tree0.add t.tree ~length:t.length ~key ~data ~compare_key:(compare_key t))
  ;;
  let add_multi t ~key ~data =
    like t
      (Tree0.add_multi t.tree ~length:t.length ~key ~data ~compare_key:(compare_key t))
  ;;
  let remove_multi t key =
    like t (Tree0.remove_multi t.tree ~length:t.length key ~compare_key:(compare_key t))
  ;;
  let change t key ~f =
    like t (Tree0.change t.tree key ~f ~length:t.length ~compare_key:(compare_key t))
  ;;
  let update t key ~f = change t key ~f:(fun data -> Some (f data))
  let find_exn t key = Tree0.find_exn t.tree key ~compare_key:(compare_key t)
  let find t key = Tree0.find t.tree key ~compare_key:(compare_key t)
  let remove t key =
    like t (Tree0.remove t.tree key ~length:t.length ~compare_key:(compare_key t))
  ;;
  let mem t key = Tree0.mem t.tree key ~compare_key:(compare_key t)
  let iteri t ~f = Tree0.iteri t.tree ~f

  (* DEPRECATED - leaving here for a little while so as to ease the transition for
     external core users. (But marking as deprecated in the mli *)
  let iter = iteri

  let iter_keys t ~f = Tree0.iter_keys t.tree ~f
  let iter2 t1 t2 ~f = Tree0.iter2 t1.tree t2.tree ~f ~compare_key:(compare_key t1)
  let map t ~f = with_same_length t (Tree0.map t.tree ~f)
  let mapi t ~f = with_same_length t (Tree0.mapi t.tree ~f)
  let fold t ~init ~f = Tree0.fold t.tree ~f ~init
  let fold_right t ~init ~f = Tree0.fold_right t.tree ~f ~init
  let fold2 t1 t2 ~init ~f =
    Tree0.fold2 t1.tree t2.tree ~init ~f ~compare_key:(compare_key t1)
  ;;
  let filteri t ~f = like t (Tree0.filteri t.tree ~f ~compare_key:(compare_key t))

  (* DEPRECATED - leaving here for a little while so as to ease the transition for
     external core users. (But marking as deprecated in the mli *)
  let filter = filteri

  let filter_keys t ~f = like t (Tree0.filter_keys t.tree ~f ~compare_key:(compare_key t))
  let filter_map t ~f = like t (Tree0.filter_map t.tree ~f ~compare_key:(compare_key t))
  let filter_mapi t ~f = like t (Tree0.filter_mapi t.tree ~f ~compare_key:(compare_key t))

  let partition_mapi t ~f =
    like2 t (Tree0.partition_mapi t.tree ~f ~compare_key:(compare_key t))
  ;;
  let partition_map t ~f =
    like2 t (Tree0.partition_map t.tree ~f ~compare_key:(compare_key t))
  ;;
  let partitioni_tf t ~f =
    like2 t (Tree0.partitioni_tf t.tree ~f ~compare_key:(compare_key t))
  ;;
  let partition_tf t ~f =
    like2 t (Tree0.partition_tf t.tree ~f ~compare_key:(compare_key t))
  ;;

  let compare_direct compare_data t1 t2 =
    Tree0.compare (compare_key t1) compare_data t1.tree t2.tree
  ;;
  let equal compare_data t1 t2 =
    Tree0.equal (compare_key t1) compare_data t1.tree t2.tree
  ;;
  let keys t = Tree0.keys t.tree
  let data t = Tree0.data t.tree
  let to_alist ?key_order t = Tree0.to_alist ?key_order t.tree
  let validate ~name f t = Validate.alist ~name f (to_alist t)
  let symmetric_diff t1 t2 ~data_equal =
    Tree0.symmetric_diff t1.tree t2.tree ~compare_key:(compare_key t1) ~data_equal
  ;;
  let merge t1 t2 ~f =
    like t1 (Tree0.merge t1.tree t2.tree ~f ~compare_key:(compare_key t1))
  ;;
  let min_elt t = Tree0.min_elt t.tree
  let min_elt_exn t = Tree0.min_elt_exn t.tree
  let max_elt t = Tree0.max_elt t.tree
  let max_elt_exn t = Tree0.max_elt_exn t.tree
  let for_all  t ~f = Tree0.for_all  t.tree ~f
  let for_alli t ~f = Tree0.for_alli t.tree ~f
  let exists   t ~f = Tree0.exists   t.tree ~f
  let existsi  t ~f = Tree0.existsi  t.tree ~f
  let count    t ~f = Tree0.count    t.tree ~f
  let counti   t ~f = Tree0.counti   t.tree ~f
  let split t k =
    let l, maybe, r = Tree0.split t.tree k ~compare_key:(compare_key t) in
    (of_tree l ~comparator:(comparator t), maybe, of_tree r ~comparator:(comparator t))
  ;;
  let fold_range_inclusive t ~min ~max ~init ~f =
    Tree0.fold_range_inclusive t.tree ~min ~max ~init ~f ~compare_key:(compare_key t)
  ;;
  let range_to_alist t ~min ~max =
    Tree0.range_to_alist t.tree ~min ~max ~compare_key:(compare_key t)
  ;;
  let closest_key t dir key = Tree0.closest_key t.tree dir key ~compare_key:(compare_key t)
  let nth t n = Tree0.nth t.tree n
  let nth_exn t n = nth t n |> Option.value_exn
  let rank t key = Tree0.rank t.tree key ~compare_key:(compare_key t)
  let sexp_of_t sexp_of_k sexp_of_v t = Tree0.sexp_of_t sexp_of_k sexp_of_v t.tree
  let to_sequence ?order ?keys_greater_or_equal_to ?keys_less_or_equal_to t =
    Tree0.to_sequence t.comparator ?order ?keys_greater_or_equal_to
      ?keys_less_or_equal_to t.tree
end

let empty ~comparator = { tree = Tree0.empty; comparator; length = 0 }

let singleton ~comparator k v = { comparator; tree = Tree0.singleton k v; length = 1 }

let of_tree0 ~comparator (tree, length) =
  { comparator; tree; length }

let of_sorted_array_unchecked ~comparator array =
  of_tree0 ~comparator
    (Tree0.of_sorted_array_unchecked array ~compare_key:comparator.Comparator.compare)
;;

let of_sorted_array ~comparator array =
  Or_error.map (Tree0.of_sorted_array array ~compare_key:comparator.Comparator.compare)
    ~f:(fun tree -> of_tree0 ~comparator tree)
;;

let of_alist ~comparator alist =
  match Tree0.of_alist alist ~compare_key:comparator.Comparator.compare with
  | `Ok (tree, length) -> `Ok { comparator; tree; length }
  | `Duplicate_key _ as z -> z
;;

let of_alist_or_error ~comparator alist =
  Result.map (Tree0.of_alist_or_error alist ~comparator)
    ~f:(fun tree -> of_tree0 ~comparator tree)
;;

let of_alist_exn ~comparator alist =
  of_tree0 ~comparator (Tree0.of_alist_exn alist ~comparator)
;;

let of_alist_multi ~comparator alist =
  of_tree0 ~comparator
    (Tree0.of_alist_multi alist ~compare_key:comparator.Comparator.compare)
;;

let of_alist_fold ~comparator alist ~init ~f =
  of_tree0 ~comparator
    (Tree0.of_alist_fold alist ~init ~f ~compare_key:comparator.Comparator.compare)
;;

let of_alist_reduce ~comparator alist ~f =
  of_tree0 ~comparator
    (Tree0.of_alist_reduce alist ~f ~compare_key:comparator.Comparator.compare)
;;

let t_of_sexp ~comparator k_of_sexp v_of_sexp sexp =
  of_tree0 ~comparator (Tree0.t_of_sexp k_of_sexp v_of_sexp sexp ~comparator)
;;

module For_quickcheck = struct

  module Generator = Quickcheck.Generator
  module Observer  = Quickcheck.Observer
  module Shrinker  = Quickcheck.Shrinker

  open Accessors_without_quickcheckable
  open Generator.Monad_infix

  let gen_alist k_gen v_gen =
    List.gen' k_gen ~unique:true ~sorted:`Arbitrarily
    >>= fun ks ->
    List.gen' v_gen ~length:(`Exactly (List.length ks))
    >>| fun vs ->
    List.zip_exn ks vs

  let gen_tree ~comparator k_gen v_gen =
    gen_alist k_gen v_gen
    >>| Tree0.of_alist_exn ~comparator
    >>| fst

  let gen ~comparator k_gen v_gen =
    gen_alist k_gen v_gen
    >>| of_alist_exn ~comparator

  let obs_alist k_obs v_obs =
    List.obs (Observer.tuple2 k_obs v_obs)

  let obs_tree k_obs v_obs =
    Observer.unmap (obs_alist k_obs v_obs)
      ~f:Tree0.to_alist
      ~f_sexp:(fun () -> Atom "Map.Tree.to_alist")

  let obs k_obs v_obs =
    Observer.unmap (obs_alist k_obs v_obs)
      ~f:to_alist
      ~f_sexp:(fun () -> Atom "Map.to_alist")

  let shrink k_shr v_shr t =
    let seq = to_sequence t in
    let drop_keys =
      Sequence.map seq ~f:(fun (k, _) ->
        remove t k)
    in
    let shrink_keys =
      Sequence.interleave (Sequence.map seq ~f:(fun (k, v) ->
        Sequence.map (Shrinker.shrink k_shr k) ~f:(fun k' ->
          add (remove t k) ~key:k' ~data:v)))
    in
    let shrink_values =
      Sequence.interleave (Sequence.map seq ~f:(fun (k, v) ->
        Sequence.map (Shrinker.shrink v_shr v) ~f:(fun v' ->
          add t ~key:k ~data:v')))
    in
    [ drop_keys; shrink_keys; shrink_values ]
    |> Sequence.of_list
    |> Sequence.interleave

  let shr_tree ~comparator k_shr v_shr =
    Shrinker.create (fun tree ->
      of_tree ~comparator tree
      |> shrink k_shr v_shr
      |> Sequence.map ~f:to_tree)

  let shrinker k_shr v_shr =
    Shrinker.create (fun t ->
      shrink k_shr v_shr t)

end

let gen = For_quickcheck.gen
let obs = For_quickcheck.obs
let shrinker = For_quickcheck.shrinker

module Accessors = struct
  include Accessors_without_quickcheckable

  let obs k v = obs k v
  let shrinker k v = shrinker k v
end

module Creators (Key : Comparator.S1) : sig

  type ('a, 'b, 'c) t_ = ('a Key.t, 'b, Key.comparator_witness) t
  type ('a, 'b, 'c) tree = ('a, 'b) Tree0.t
  type ('a, 'b, 'c) options = ('a, 'b, 'c) Without_comparator.t

  val t_of_sexp : (Sexp.t -> 'a Key.t) -> (Sexp.t -> 'b) -> Sexp.t -> ('a, 'b, _) t_

  include Creators_generic
    with type ('a, 'b, 'c) t    := ('a, 'b, 'c) t_
    with type ('a, 'b, 'c) tree := ('a, 'b, 'c) tree
    with type 'a key := 'a Key.t
    with type ('a, 'b, 'c) options := ('a, 'b, 'c) options

end = struct

  type ('a, 'b, 'c) options = ('a, 'b, 'c) Without_comparator.t

  let comparator = Key.comparator

  type ('a, 'b, 'c) t_ = ('a Key.t, 'b, Key.comparator_witness) t

  type ('a, 'b, 'c) tree = ('a, 'b) Tree0.t

  let empty = { tree = Tree0.empty; comparator; length = 0 }

  let of_tree tree = of_tree ~comparator tree

  let singleton k v = singleton ~comparator k v

  let of_sorted_array_unchecked array = of_sorted_array_unchecked ~comparator array

  let of_sorted_array array = of_sorted_array ~comparator array

  let of_alist alist = of_alist ~comparator alist

  let of_alist_or_error alist = of_alist_or_error ~comparator alist

  let of_alist_exn alist = of_alist_exn ~comparator alist

  let of_alist_multi alist = of_alist_multi ~comparator alist

  let of_alist_fold alist ~init ~f = of_alist_fold ~comparator alist ~init ~f

  let of_alist_reduce alist ~f = of_alist_reduce ~comparator alist ~f

  let t_of_sexp k_of_sexp v_of_sexp sexp = t_of_sexp ~comparator k_of_sexp v_of_sexp sexp

  let gen gen_k gen_v = gen ~comparator gen_k gen_v

end

include Accessors

(* [0] is used as the [length] argument everywhere in this module, since trees do not
   have their lengths stored at the root, unlike maps. The values are discarded always. *)
module Make_tree (Key : Comparator.S1) = struct
  let comparator = Key.comparator

  let empty = Tree0.empty
  let of_tree tree = tree
  let singleton k v = Tree0.singleton k v
  let of_sorted_array_unchecked array =
    fst (Tree0.of_sorted_array_unchecked array ~compare_key:comparator.Comparator.compare)
  ;;
  let of_sorted_array array =
    Tree0.of_sorted_array array ~compare_key:comparator.Comparator.compare
    |> Or_error.map ~f:fst
  ;;
  let of_alist alist =
    match Tree0.of_alist alist ~compare_key:comparator.Comparator.compare with
    | `Duplicate_key _ as d -> d
    | `Ok (tree, _size) -> `Ok tree
  ;;
  let of_alist_or_error alist =
    Or_error.map ~f:fst (Tree0.of_alist_or_error alist ~comparator)
  ;;
  let of_alist_exn alist = fst (Tree0.of_alist_exn alist ~comparator)
  let of_alist_multi alist =
    fst (Tree0.of_alist_multi alist ~compare_key:comparator.Comparator.compare)
  ;;
  let of_alist_fold alist ~init ~f =
    Tree0.of_alist_fold alist ~init ~f ~compare_key:comparator.Comparator.compare
    |> fst
  ;;
  let of_alist_reduce alist ~f =
    Tree0.of_alist_reduce alist ~f ~compare_key:comparator.Comparator.compare
    |> fst
  ;;

  let to_tree t = t
  let invariants t = Tree0.invariants t ~compare_key:comparator.Comparator.compare
  let is_empty t = Tree0.is_empty t
  let length t = Tree0.length t
  let add t ~key ~data =
    fst (Tree0.add t ~key ~data ~length:0 ~compare_key:comparator.Comparator.compare)
  ;;
  let add_multi t ~key ~data =
    fst (Tree0.add_multi t ~key ~data ~length:0 ~compare_key:comparator.Comparator.compare)
  ;;
  let remove_multi t key =
    fst (Tree0.remove_multi t key ~length:0 ~compare_key:comparator.Comparator.compare)
  ;;
  let change t key ~f =
    fst (Tree0.change t key ~f ~length:0 ~compare_key:comparator.Comparator.compare)
  ;;
  let update t key ~f = change t key ~f:(fun data -> Some (f data))
  let find_exn t key =
    Tree0.find_exn t key ~compare_key:comparator.Comparator.compare
  ;;
  let find t key =
    Tree0.find t key ~compare_key:comparator.Comparator.compare
  ;;
  let remove t key =
    fst (Tree0.remove t key ~length:0 ~compare_key:comparator.Comparator.compare)
  ;;
  let mem t key = Tree0.mem t key ~compare_key:comparator.Comparator.compare
  let iteri t ~f = Tree0.iteri t ~f

  (* DEPRECATED - leaving here for a little while so as to ease the transition for
     external core users. (But marking as deprecated in the mli *)
  let iter = iteri

  let iter_keys t ~f = Tree0.iter_keys t ~f
  let iter2 t1 t2 ~f = Tree0.iter2 t1 t2 ~f ~compare_key:comparator.Comparator.compare
  let map  t ~f = Tree0.map  t ~f
  let mapi t ~f = Tree0.mapi t ~f
  let fold       t ~init ~f = Tree0.fold       t ~f ~init
  let fold_right t ~init ~f = Tree0.fold_right t ~f ~init
  let fold2 t1 t2 ~init ~f =
    Tree0.fold2 t1 t2 ~init ~f ~compare_key:comparator.Comparator.compare
  ;;
  let filteri t ~f =
    fst (Tree0.filteri t ~f ~compare_key:comparator.Comparator.compare)

  (* DEPRECATED - leaving here for a little while so as to ease the transition for
     external core users. (But marking as deprecated in the mli *)
  let filter = filteri

  let filter_keys t ~f =
    fst (Tree0.filter_keys t ~f ~compare_key:comparator.Comparator.compare)
  let filter_map t ~f =
    fst (Tree0.filter_map t ~f ~compare_key:comparator.Comparator.compare)
  let filter_mapi t ~f =
    fst (Tree0.filter_mapi t ~f ~compare_key:comparator.Comparator.compare)
  ;;
  let partition_mapi t ~f =
    let (a, _), (b, _) =
      Tree0.partition_mapi t ~f ~compare_key:comparator.Comparator.compare
    in
    (a, b)
  ;;
  let partition_map t ~f =
    let (a, _), (b, _) =
      Tree0.partition_map t ~f ~compare_key:comparator.Comparator.compare
    in
    (a, b)
  ;;
  let partitioni_tf t ~f =
    let (a, _), (b, _) =
      Tree0.partitioni_tf t ~f ~compare_key:comparator.Comparator.compare
    in
    (a, b)
  ;;
  let partition_tf t ~f =
    let (a, _), (b, _) =
      Tree0.partition_tf t ~f ~compare_key:comparator.Comparator.compare
    in
    (a, b)
  ;;
  let compare_direct compare_data t1 t2 =
    Tree0.compare comparator.Comparator.compare compare_data t1 t2
  ;;
  let equal compare_data t1 t2 =
    Tree0.equal comparator.Comparator.compare compare_data t1 t2
  ;;
  let keys t = Tree0.keys t
  let data t = Tree0.data t
  let to_alist ?key_order t = Tree0.to_alist ?key_order t
  let validate ~name f t = Validate.alist ~name f (to_alist t)
  let symmetric_diff t1 t2 ~data_equal =
    Tree0.symmetric_diff t1 t2 ~compare_key:comparator.Comparator.compare ~data_equal
  ;;
  let merge t1 t2 ~f =
    fst (Tree0.merge t1 t2 ~f ~compare_key:comparator.Comparator.compare)
  let min_elt     t = Tree0.min_elt     t
  let min_elt_exn t = Tree0.min_elt_exn t
  let max_elt     t = Tree0.max_elt     t
  let max_elt_exn t = Tree0.max_elt_exn t
  let for_all  t ~f = Tree0.for_all  t ~f
  let for_alli t ~f = Tree0.for_alli t ~f
  let exists   t ~f = Tree0.exists   t ~f
  let existsi  t ~f = Tree0.existsi  t ~f
  let count    t ~f = Tree0.count    t ~f
  let counti   t ~f = Tree0.counti   t ~f
  let split t k = Tree0.split t k ~compare_key:comparator.Comparator.compare
  let fold_range_inclusive t ~min ~max ~init ~f =
    Tree0.fold_range_inclusive t ~min ~max ~init ~f
      ~compare_key:comparator.Comparator.compare
  ;;
  let range_to_alist t ~min ~max =
    Tree0.range_to_alist t ~min ~max ~compare_key:comparator.Comparator.compare
  ;;
  let closest_key t dir key =
    Tree0.closest_key t dir key ~compare_key:comparator.Comparator.compare
  ;;
  let nth t n =
    Tree0.nth t n
  ;;
  let rank t key = Tree0.rank t key ~compare_key:comparator.Comparator.compare

  let to_sequence ?order ?keys_greater_or_equal_to ?keys_less_or_equal_to t =
    Tree0.to_sequence comparator ?order ?keys_greater_or_equal_to
      ?keys_less_or_equal_to t

  let gen k v =
    For_quickcheck.gen_tree ~comparator k v

  let obs k v =
    For_quickcheck.obs_tree k v

  let shrinker k v =
    For_quickcheck.shr_tree ~comparator k v
end

(* Don't use [of_sorted_array] to avoid the allocation of an intermediate array *)
let init_for_bin_prot ~len ~f ~comparator =
  let tree = Tree0.init_unsafe ~len ~f in
  let compare_key = comparator.Comparator.compare in
  let tree =
    if Tree0.invariants ~compare_key tree
    then tree
    else (Tree0.fold tree ~init:(Tree0.Empty,0) ~f:(fun ~key ~data (acc,size) ->
      if Tree0.mem acc key ~compare_key
      then failwith "Map.bin_read_t: duplicate element in map"
      else Tree0.add acc ~length:size ~key ~data ~compare_key)
          |> fst)
  in
  of_tree0 ~comparator (tree, len)
;;

module Poly = struct
  include Creators (Comparator.Poly)

  type ('a, 'b, 'c) map = ('a, 'b, 'c) t
  type ('k, 'v) t = ('k, 'v, Comparator.Poly.comparator_witness) map

  include Accessors

  let compare _ cmpv t1 t2 = compare_direct cmpv t1 t2

  let sexp_of_t = sexp_of_t

  include Bin_prot.Utils.Make_iterable_binable2 (struct
      type nonrec ('a, 'b) t = ('a, 'b) t
      type ('a, 'b) el = 'a * 'b [@@deriving bin_io]
      let _ = bin_el
      let module_name = Some "Core.Std.Map"
      let length = length
      let iter t ~f = iteri t ~f:(fun ~key ~data -> f (key, data))
      let init ~len ~next =
        init_for_bin_prot
          ~len
          ~f:(fun _ -> next ())
          ~comparator:Comparator.Poly.comparator
    end)


  module Tree = struct
    include Make_tree (Comparator.Poly)
    type ('k, +'v) t = ('k, 'v, Comparator.Poly.comparator_witness) tree

    let sexp_of_t sexp_of_k sexp_of_v t = Tree0.sexp_of_t sexp_of_k sexp_of_v t
    let t_of_sexp k_of_sexp v_of_sexp sexp =
      fst (Tree0.t_of_sexp k_of_sexp v_of_sexp ~comparator:Comparator.Poly.comparator sexp)
  end
end

module type Key = Key
module type Key_binable = Key_binable

module type S = S
  with type ('a, 'b, 'c) map  := ('a, 'b, 'c) t
  with type ('a, 'b, 'c) tree := ('a, 'b, 'c) tree

module type S_binable = S_binable
  with type ('a, 'b, 'c) map  := ('a, 'b, 'c) t
  with type ('a, 'b, 'c) tree := ('a, 'b, 'c) tree

module Make_using_comparator (Key : sig
  type t [@@deriving sexp]
  include Comparator.S with type t := t
end) = struct

  module Key = Key

  module Key_S1 = Comparator.S_to_S1 (Key)
  include Creators (Key_S1)

  type key = Key.t
  type ('a, 'b, 'c) map = ('a, 'b, 'c) t
  type 'v t = (key, 'v, Key.comparator_witness) map

  include Accessors

  let compare cmpv t1 t2 = compare_direct cmpv t1 t2

  let sexp_of_t sexp_of_v t = sexp_of_t Key.sexp_of_t sexp_of_v t

  let t_of_sexp v_of_sexp sexp = t_of_sexp Key.t_of_sexp v_of_sexp sexp

  module Tree = struct
    include Make_tree (Key_S1)
    type +'v t = (Key.t, 'v, Key.comparator_witness) tree

    let sexp_of_t sexp_of_v t = Tree0.sexp_of_t Key.sexp_of_t sexp_of_v t
    let t_of_sexp v_of_sexp sexp =
      Tree0.t_of_sexp Key.t_of_sexp v_of_sexp ~comparator:Key.comparator sexp
      |> fst
  end
end

module Make (Key : Key) =
  Make_using_comparator (struct
    include Key
    include Comparator.Make (Key)
  end)

module Make_binable_using_comparator (Key' : sig
  type t [@@deriving bin_io, sexp]
  include Comparator.S with type t := t
end) = struct

  include Make_using_comparator (Key')
  include Bin_prot.Utils.Make_iterable_binable1 (struct
      type nonrec 'v t = 'v t
      type 'v el = Key'.t * 'v [@@deriving bin_io]
      let _ = bin_el
      let module_name = Some "Core.Std.Map"
      let length = length
      let iter t ~f = iteri t ~f:(fun ~key ~data -> f (key, data))
      let init ~len ~next =
        init_for_bin_prot
          ~len
          ~f:(fun _ -> next ())
          ~comparator:Key'.comparator
    end)
end

module Make_binable (Key : Key_binable) =
  Make_binable_using_comparator (struct
    include Key
    include Comparator.Make (Key)
  end)

(* As with [Make_tree], this module uses [0] as [length] everywhere. *)
module Tree = struct
  type ('k, 'v, 'comparator) t = ('k, 'v, 'comparator) tree

  let empty ~comparator:_ = Tree0.empty
  let of_tree ~comparator:_ tree = tree
  let singleton ~comparator:_ k v = Tree0.singleton k v
  let of_sorted_array_unchecked ~comparator array =
    fst (Tree0.of_sorted_array_unchecked array ~compare_key:comparator.Comparator.compare)
  ;;
  let of_sorted_array ~comparator array =
    Tree0.of_sorted_array array ~compare_key:comparator.Comparator.compare
    |> Or_error.map ~f:fst
  ;;
  let of_alist ~comparator alist =
    match Tree0.of_alist alist ~compare_key:comparator.Comparator.compare with
    | `Duplicate_key _ as d -> d
    | `Ok (tree, _size) -> `Ok tree
  ;;
  let of_alist_or_error ~comparator alist =
    Tree0.of_alist_or_error alist ~comparator
    |> Or_error.map ~f:fst
  let of_alist_exn ~comparator alist = fst (Tree0.of_alist_exn alist ~comparator)
  let of_alist_multi ~comparator alist =
    fst (Tree0.of_alist_multi alist ~compare_key:comparator.Comparator.compare)
  ;;
  let of_alist_fold ~comparator alist ~init ~f =
    fst (Tree0.of_alist_fold alist ~init ~f ~compare_key:comparator.Comparator.compare)
  ;;
  let of_alist_reduce ~comparator alist ~f =
    fst (Tree0.of_alist_reduce alist ~f ~compare_key:comparator.Comparator.compare)
  ;;

  let to_tree t = t
  let invariants ~comparator t =
    Tree0.invariants t ~compare_key:comparator.Comparator.compare
  ;;
  let is_empty t = Tree0.is_empty t
  let length t = Tree0.length t
  let add ~comparator t ~key ~data =
    fst (Tree0.add t ~key ~data ~length:0 ~compare_key:comparator.Comparator.compare)
  ;;
  let add_multi ~comparator t ~key ~data =
    Tree0.add_multi t ~key ~data ~length:0 ~compare_key:comparator.Comparator.compare
    |> fst
  ;;
  let remove_multi ~comparator t key =
    Tree0.remove_multi t key ~length:0 ~compare_key:comparator.Comparator.compare
    |> fst
  ;;
  let change ~comparator t key ~f =
    fst (Tree0.change t key ~f ~length:0 ~compare_key:comparator.Comparator.compare)
  ;;
  let update ~comparator t key ~f = change ~comparator t key ~f:(fun data -> Some (f data))
  let find_exn ~comparator t key =
    Tree0.find_exn t key ~compare_key:comparator.Comparator.compare
  ;;
  let find ~comparator t key =
    Tree0.find t key ~compare_key:comparator.Comparator.compare
  ;;
  let remove ~comparator t key =
    fst (Tree0.remove t key ~length:0 ~compare_key:comparator.Comparator.compare)
  ;;
  let mem ~comparator t key = Tree0.mem t key ~compare_key:comparator.Comparator.compare
  let iteri t ~f = Tree0.iteri t ~f

  (* DEPRECATED - leaving here for a little while so as to ease the transition for
     external core users. (But marking as deprecated in the mli *)
  let iter = iteri

  let iter_keys t ~f = Tree0.iter_keys t ~f
  let iter2 ~comparator t1 t2 ~f =
    Tree0.iter2 t1 t2 ~f ~compare_key:comparator.Comparator.compare
  ;;
  let map  t ~f = Tree0.map  t ~f
  let mapi t ~f = Tree0.mapi t ~f
  let fold       t ~init ~f = Tree0.fold       t ~f ~init
  let fold_right t ~init ~f = Tree0.fold_right t ~f ~init
  let fold2 ~comparator t1 t2 ~init ~f =
    Tree0.fold2 t1 t2 ~init ~f ~compare_key:comparator.Comparator.compare
  ;;
  let filteri ~comparator t ~f =
    fst (Tree0.filteri t ~f ~compare_key:comparator.Comparator.compare)
  ;;

  (* DEPRECATED - leaving here for a little while so as to ease the transition for
     external core users. (But marking as deprecated in the mli *)
  let filter = filteri

  let filter_keys ~comparator t ~f =
    fst (Tree0.filter_keys t ~f ~compare_key:comparator.Comparator.compare)
  ;;
  let filter_map ~comparator t ~f =
    fst (Tree0.filter_map t ~f ~compare_key:comparator.Comparator.compare)
  ;;
  let filter_mapi ~comparator t ~f =
    fst (Tree0.filter_mapi t ~f ~compare_key:comparator.Comparator.compare)
  ;;
  let partition_mapi ~comparator t ~f =
    let (a, _), (b, _) =
      Tree0.partition_mapi t ~f ~compare_key:comparator.Comparator.compare
    in
    (a, b)
  ;;
  let partition_map ~comparator t ~f =
    let (a, _), (b, _) =
      Tree0.partition_map t ~f ~compare_key:comparator.Comparator.compare
    in
    (a, b)
  ;;
  let partitioni_tf ~comparator t ~f =
    let (a, _), (b, _) =
      Tree0.partitioni_tf t ~f ~compare_key:comparator.Comparator.compare
    in
    (a, b)
  ;;
  let partition_tf ~comparator t ~f =
    let (a, _), (b, _) =
      Tree0.partition_tf t ~f ~compare_key:comparator.Comparator.compare
    in
    (a, b)
  ;;
  let compare_direct ~comparator compare_data t1 t2 =
    Tree0.compare comparator.Comparator.compare compare_data t1 t2
  ;;
  let equal ~comparator compare_data t1 t2 =
    Tree0.equal comparator.Comparator.compare compare_data t1 t2
  ;;
  let keys t = Tree0.keys t
  let data t = Tree0.data t
  let to_alist ?key_order t = Tree0.to_alist ?key_order t
  let validate ~name f t = Validate.alist ~name f (to_alist t)
  let symmetric_diff ~comparator t1 t2 ~data_equal =
    Tree0.symmetric_diff t1 t2 ~compare_key:comparator.Comparator.compare ~data_equal
  ;;
  let merge ~comparator t1 t2 ~f =
    fst (Tree0.merge t1 t2 ~f ~compare_key:comparator.Comparator.compare)
  ;;
  let min_elt     t = Tree0.min_elt     t
  let min_elt_exn t = Tree0.min_elt_exn t
  let max_elt     t = Tree0.max_elt     t
  let max_elt_exn t = Tree0.max_elt_exn t
  let for_all  t ~f = Tree0.for_all  t ~f
  let for_alli t ~f = Tree0.for_alli t ~f
  let exists   t ~f = Tree0.exists   t ~f
  let existsi  t ~f = Tree0.existsi  t ~f
  let count    t ~f = Tree0.count    t ~f
  let counti   t ~f = Tree0.counti   t ~f
  let split ~comparator t k = Tree0.split t k ~compare_key:comparator.Comparator.compare
  let fold_range_inclusive ~comparator t ~min ~max ~init ~f =
    Tree0.fold_range_inclusive t ~min ~max ~init ~f
      ~compare_key:comparator.Comparator.compare
  ;;
  let range_to_alist ~comparator t ~min ~max =
    Tree0.range_to_alist t ~min ~max ~compare_key:comparator.Comparator.compare
  ;;
  let closest_key ~comparator t dir key =
    Tree0.closest_key t dir key ~compare_key:comparator.Comparator.compare
  ;;
  let nth ~comparator:_ t n = Tree0.nth t n
  let rank ~comparator t key = Tree0.rank t key ~compare_key:comparator.Comparator.compare
  let sexp_of_t sexp_of_k sexp_of_v _ t = Tree0.sexp_of_t sexp_of_k sexp_of_v t

  let to_sequence ~comparator ?order ?keys_greater_or_equal_to ?keys_less_or_equal_to t
    =
    Tree0.to_sequence comparator ?order ?keys_greater_or_equal_to ?keys_less_or_equal_to
      t

  let gen ~comparator k v =
    For_quickcheck.gen_tree ~comparator k v
  let obs k v =
    For_quickcheck.obs_tree k v
  let shrinker ~comparator k v =
    For_quickcheck.shr_tree ~comparator k v
end
