structure Preprocess =
struct

  open Ceptre
  open Parse

  exception IllFormed
  exception Unimp

  (* translating from Parse.syn to Ceptre.external_rule *)

  fun caps s =
    case String.explode s of
         [] => raise IllFormed
       | (c::_) => Char.isUpper c

  val wild_gensym = ref 0
  fun wild () = 
    let
      val w = !wild_gensym
      val () = wild_gensym := w + 1
    in
      w
    end

  fun extractTerm syn =
    case syn of
         Id id => if caps id 
                  then EVar id
                  else EFn (id, [])
       | App (f, args) =>
           let
             val termArgs = map extractTerm args
           in
             case extractTerm f of
                  EFn (f, []) => EFn (f, termArgs)
                | _ => raise IllFormed
           end
       | Wild () => EVar ("_X"^Int.toString (wild ()))
       | _ => raise IllFormed

  (* Stuff without vars can go directly into IL syntax *)
  fun extractGroundTerm syn =
    case syn of
         Id id => if caps id then raise IllFormed else
                  Fn (id, [])
       | App (f, args) =>
           let
             val termArgs = map extractGroundTerm args
           in
             case extractGroundTerm f of
                  Fn (f, []) => Fn (f, termArgs)
                | _ => raise IllFormed
           end
       | _ => raise IllFormed 

  fun extractAtom syn rhs =
    case syn of
         Bang syn =>
           let
             val (at, rhs) = extractAtom syn rhs
           in
             case at of
                  ELin at => (EPers at, rhs)
                | _ => raise IllFormed
           end
       | Dollar syn => 
           let
             val (at, rhs) = extractAtom syn rhs
           in
             case at of
                  (* $A means A added to RHS *)
                  ELin at => (ELin at, (ELin at)::rhs)
                | _ => raise IllFormed
           end
       | Id pred => (ELin (pred,[]), rhs)
       | App (Id pred, args) =>
           let
             val argTerms = map extractTerm args
           in
             (ELin (pred, argTerms), rhs)
           end
       | _ => raise IllFormed
  
  (* Stuff without vars can go directly into IL syntax *)
  fun extractGroundAtom syn =
    case syn of
         Bang syn =>
         let
           val at = extractGroundAtom syn 
         in
           case at of
                (Lin, p, args) => (Pers, p, args)
              | _ => raise IllFormed 
         end
       | Id pred => (Lin, pred, [])
       | App (Id pred, args) =>
           let
             val argTerms = map extractGroundTerm args
           in
             (Lin, pred, argTerms)
           end
       | _ => raise IllFormed

  fun extractLHS syn acc rhs =
    case syn of
         Star (a, lhs) =>
           let
             val (atom, rhs) = extractAtom a rhs
           in
               extractLHS lhs (fn x => atom::(acc x)) rhs
           end
       | syn => 
           let
             val (atom, rhs) = extractAtom syn rhs
           in
             (acc atom, rhs)
           end

  fun extractRHSAtom syn =
    case extractAtom syn [] of
         (atom, []) => atom
        | _ => raise IllFormed

  fun extractRHS syn acc =
    case syn of
         Star (a, rhs) =>
         (case extractAtom a [] of
               (atom, []) => extractRHS rhs (atom::acc)
              | _ => raise IllFormed)
       | syn => 
           (case extractAtom syn [] of
                 (atom, []) => atom::acc
               | _ => raise IllFormed)


  fun declToRule sg syntax =
    case syntax of
          Decl (Ascribe (App (Id name, []), 
                Lolli (lhs_syn, rhs_syn))) => (* XXX MATCH ERROR - RJS *)
            let
              val (lhs, residual) = extractLHS lhs_syn (fn x => [x]) []
              val rhs = 
                case rhs_syn of NONE => []
                   | SOME rhs_syn => extractRHS rhs_syn residual
              (* external syntax *)
              val erule = {name = name, lhs = lhs, rhs = rhs}
              val () = wild_gensym := 0 (* reset for each rule *)
            in
              externalToInternal sg erule
            end
        | _ => raise IllFormed

  fun separate f l =
  let
    fun help f prefix [] = NONE
      | help f prefix (x::xs) = 
          if f x then SOME (x, prefix xs)
          else help f (fn postfix => (prefix (x::postfix))) xs
  in
    help f (fn x => x) l
  end

  fun stageAtom (Lin, p, args) = p = "stage"
    | stageAtom _ = false

  (* XXX hardcode stage keyword? *)
  (* XXX stages with arguments? *)
  fun ruleToStageRule {name, pivars, lhs, rhs} =
    case separate stageAtom lhs of
         SOME ((Lin, "stage", [Fn (pre_stage, [])]), lhs') =>
    (case separate stageAtom rhs of
          SOME ((Lin, "stage", [Fn (post_stage, [])]), rhs') =>
            SOME
            {name=name, pivars=pivars, lhs=lhs', rhs=rhs',
            pre_stage=pre_stage, post_stage=post_stage}
        | _ => NONE)
        | _ => NONE

  fun extractContext top =
    case top of
         Context (name, atoms) => (name, map extractGroundAtom atoms)
       | _ => raise IllFormed

  fun extractStage sg syntax =
    case syntax of
          Stage (name, rules_syntax) =>
          let
            val rules = map (declToRule sg) rules_syntax
          in
            {name = name, body = rules}
          end
        | _ => raise IllFormed

  (* interpret a Special "#trace" *)
  fun extractProgram top =
    case top of
         Special ("trace", [limit, Id stage, Id ctx]) =>
              (NONE, stage, ctx) (* XXX someday first elt should be limit *)
       | _ => raise IllFormed

  fun extractID (Id f) = f
    | extractID (App (Id f, [])) = f
    | extractID _ = raise IllFormed

  fun extractPredDecl data predclass =
    let
      val Fn (id, args) = extractGroundTerm data
    in
      (id, Ceptre.Pred (predclass, args))
    end

  fun extractIDTms (Fn (i, [])) = i
    | extractIDTms _ = raise IllFormed
  
  datatype csyn = CStage of stage | CRule of rule_internal 
                | CNone of syn
                | CError of top 
                | CCtx of ident * context  (* named ctx *)
                | CProg of (int option) * ident * ident 
                    (* limit, initial phase & initial ctx *)
                | CDecl of decl
                | CBwd of bwd_rule

  (* checks decl wrt sg *)
  fun extractDecl sg top =
    case top of
         Decl (Ascribe (data, class)) =>
         (case class of
               App (class, []) => extractDecl sg (Decl (Ascribe (data, class)))
            (* first-order types *)
             | Id "type" => 
               (case data of
                     (Id id) => (id, Ceptre.Type)
                   | (App (Id id, [])) => (id, Ceptre.Type)
                   | _ => raise IllFormed)
            (* predicates *)
             | Pred () => (* parse data as f t...t *)
                extractPredDecl data Ceptre.Prop
             | Id "bwd" =>
                 extractPredDecl data Ceptre.Bwd
             | Id "sense" => (* Parse as a Ceptre.Pred Bwd *)
                 extractPredDecl data Ceptre.Sense
             | Id "action" => (* parse as Ceptre.pred Act *)
                 extractPredDecl data Ceptre.Act
            (* first-order terms *)
             | Id ident => (* data : ident *)
                 (* XXX look up ident in sg.
                 * if it's a type, parse data as name * argtp list and
                 * return a (name, Ceptre.Tp (argtps, ident)) *)
                 (case lookup ident sg of
                      SOME Ceptre.Type =>
                        let
                          val Fn (name, argtps) = extractGroundTerm data
                          val idents = map extractIDTms argtps
                        in
                          (name, Ceptre.Tp (idents, ident))
                        end
                 (* if it's a bwd pred, data should just be an id. *)
                  (*  | SOME (Ceptre.Pred (Bwd, args)) =>
                        let
                          val Fn (id, []) = extractGroundTerm data
                        in
                          (* XXX nooo this won't typecheck ugh *)
                          (id, {name=id, head=(ident,[]), subgoals=[]})
                        end *)
                    | _ => raise IllFormed)
            (* backward chaining rules *)
            (* XXX get to this
             | Arrow rule =>
                 (* call another fn that parses rule as (lhs, rhs) *)
                 (* parse lhs as a predicate *)
                 (* parse rhs as another arrow or a head *)
                 (* eventually return a Ceptre.bwd_rule *)
                 *)
             | _ => raise IllFormed)
      | _ => raise IllFormed

  fun extractTop sg top =
    case top of
         Stage _ => CStage (extractStage sg top)
       | Decl (Ascribe (App (Id _, []), Lolli _)) => CRule (declToRule sg top)
       | Decl s => (CDecl (extractDecl sg top)
                      handle IllFormed => CNone s)
       | Context _ => CCtx (extractContext top)
       | Special _ => CProg (extractProgram top)

  fun csynToString (CStage stage) = stageToString stage
    | csynToString (CRule rule) = ruleToString rule
    | csynToString (CNone s) = "(" ^ (synToString s) ^ " doesn't parse yet)"
    | csynToString (CError _) = "(parse error!)"
    | csynToString (CCtx (name, ctx)) = name ^ " : " ^ (contextToString ctx)
    | csynToString (CProg (_,stg,ctx)) = "#trace * " ^ stg ^ " " ^ ctx ^ "."


  fun stage_exists s (stages : Ceptre.stage list) =
    List.exists (fn {name, body} => name = s) stages

  (* turn a whole list of top-level decls into a list of progs. *)
  fun process' tops sg contexts stages links progs =
    case tops of
         [] => progs
       | (top::tops) => 
           (case extractTop sg top of
                 CStage stage => 
                  process' tops sg contexts (stage::stages) links progs
               | CRule rule => 
                   (case ruleToStageRule rule of 
                         SOME link => 
                          process' tops sg contexts stages (link::links) progs
                       | NONE => (* XXX error? *)
                          process' tops sg contexts stages links progs)
               | CNone _ => process' tops sg contexts stages links progs
               | CError _ => process' tops sg contexts stages links progs
                            (* XXX error? *)
               | CCtx c => process' tops sg (c::contexts) stages links progs
               | CProg (limit, init_stage, init_ctx_name) =>
                   (* XXX ignore limit for now *)
                   case (stage_exists init_stage stages, 
                         lookup init_ctx_name contexts) of
                        (true, SOME init_ctx) =>
                          let
                            val prog = {stages=stages, links=links, 
                              init_stage=init_stage, init_state = init_ctx}
                          in
                            process' tops sg contexts stages links (prog::progs)
                          end
                      | _ => process' tops sg contexts stages links progs
                              (* XXX some kind of error should happen...*)
             )

  fun process tops = process' tops [] [] [] [] []

  (* testing *)
  
  fun catch f = (fn x => f x handle IllFormed => CError x)
  fun mapcatch f = map (catch f)
    
  val [tiny1, tiny2] = Parse.parsefile ("../examples/tiny.cep")

  val small = Parse.parsefile ("../examples/small.cep")

  fun sub l n = List.nth(l,n)

end