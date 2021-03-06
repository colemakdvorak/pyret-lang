#lang pyret

provide *
provide-types *
import ast as A
import srcloc as S
import parse-pyret as PP
import string-dict as SD
import file("compile-structs.arr") as C
import file("ast-util.arr") as U
import file("gensym.arr") as G
import file("type-structs.arr") as T

string-dict = SD.string-dict
mtd = [string-dict:]

names = A.global-names

type NameResolution = C.NameResolution

fun mk-bind(l, id) -> A.Expr: A.s-bind(l, false, id, A.a-blank) end

fun mk-id(loc, base) -> { id :: A.Expr, id-b :: A.Expr, id-e :: A.Expr }:
  t = A.s-name(loc, base)
  { id: t, id-b: mk-bind(loc, t), id-e: A.s-id(loc, t) }
end

fun resolve-provide(p :: A.Provide, b :: A.Expr) -> A.Provide:
  cases(A.Provide) p:
    | s-provide-all(l) =>
#      s-provide-all(l)
      ids = A.block-ids(b)
      obj = A.s-obj(l, for map(id from ids): A.s-data-field(l, id.tosourcestring(), A.s-id(l, id)) end)
      A.s-provide(l, obj)
    | else => p
  end
end

fun resolve-type-provide(p :: A.ProvideTypes, b :: A.Expr) -> A.ProvideTypes:
  cases(A.ProvideTypes) p:
    | s-provide-types-all(l) =>
      ids = A.block-type-ids(b)
      type-fields = for map(id from ids):
        if id.bind-type == "data":
          A.a-field(l, id.name.toname(), A.a-name(l, id.name))
        else:
          A.a-field(l, id.name.toname(), A.a-name(l, id.name))
        end
      end
      A.s-provide-types(l, type-fields)
    | else => p
  end
end

is-s-import-complete = A.is-s-import-complete

fun expand-import(imp :: A.Import, env :: C.CompileEnvironment) -> A.Import % (is-s-import-complete):
  cases(A.Import) imp:
    | s-import(l, shadow imp, name) =>
      A.s-import-complete(l, empty, empty, imp, name, name)
    | s-import-fields(l, fields, shadow imp) =>
      imp-str = if A.is-s-const-import(imp): imp.mod else: "mod-import" end
      A.s-import-complete(l, fields, empty, imp, A.s-underscore(l), A.s-underscore(l))
    | s-include(l, shadow imp) =>
      imp-str = if A.is-s-const-import(imp): imp.mod else: "mod-import" end
      imp-name = A.s-underscore(l)
      info-key = U.import-to-dep(imp).key()
      mod-info = env.mods.get(info-key)
      cases(Option<C.Provides>) mod-info:
        | none => raise("No compile-time information provided for module " + info-key)
        | some(provides) =>
          val-names = provides.values.keys-list().map(A.s-name(l, _))
          type-names = provides.aliases.keys-list().map(A.s-name(l, _))
          A.s-import-complete(l, val-names, type-names, imp, imp-name, imp-name)
      end
    | s-import-complete(_, _, _, _, _, _) => imp
  end
end

fun desugar-toplevel-types(stmts :: List<A.Expr>) -> List<A.Expr> block:
  doc: ```
       Treating stmts as a toplevel block, hoist any type-lets or newtype declarations
       to the top, turning them into a type-let-expression, and generate newtypes for all
       data expressions.
       ```
  var rev-type-binds = empty
  var rev-stmts = empty
  for lists.each(s from stmts):
    cases(A.Expr) s block:
      | s-type(l, name, params, ann) =>
        rev-stmts := link(s, rev-stmts)
      | s-newtype(l, name, namet) =>
        rev-type-binds := link(A.s-newtype-bind(l, name, namet), rev-type-binds)
      | s-data(l, name, params, mixins, variants, shared, _check) =>
        namet = names.make-atom(name)
        rev-type-binds := link(A.s-newtype-bind(l, A.s-name(l, name), namet), rev-type-binds)
        rev-stmts := link(A.s-data-expr(l, name, namet, params, mixins, variants, shared, _check), rev-stmts)
      | else =>
        rev-stmts := link(s, rev-stmts)
    end
  end
  if is-empty(rev-type-binds):
    stmts
  else:
    type-binds = rev-type-binds.reverse()
    new-stmts = rev-stmts.reverse()
    [list: A.s-type-let-expr(type-binds.first.l, type-binds,
        A.s-block(type-binds.first.l, new-stmts), is-link(new-stmts.rest))]
  end
end

data BindingGroup:
  | let-binds(binds :: List<A.LetBind>)
  | letrec-binds(binds :: List<A.LetrecBind>)
  | type-let-binds(binds :: List<A.TypeLetBind>)
end

fun bind-wrap(bg, expr) -> A.Expr:
  cases(List) bg.binds:
    | empty => expr
    | else =>
      cases(BindingGroup) bg:
        | let-binds(binds) =>
          A.s-let-expr(binds.first.l, binds.reverse(), expr, false)
        | letrec-binds(binds) =>
          A.s-letrec(binds.first.l, binds.reverse(), expr, false)
        | type-let-binds(binds) =>
          A.s-type-let-expr(binds.first.l, binds.reverse(), expr, false)
      end
  end
end

fun add-letrec-bind(bg :: BindingGroup, lrb :: A.LetrecBind, stmts :: List<A.Expr>) -> A.Expr:
  add-letrec-binds(bg, [list: lrb], stmts)
end

fun add-letrec-binds(bg :: BindingGroup, lrbs :: List<A.LetrecBind>, stmts :: List<A.Expr>) -> A.Expr:
  cases(BindingGroup) bg:
    | letrec-binds(binds) =>
      desugar-scope-block(stmts, letrec-binds(lrbs + binds))
    | else =>
      bind-wrap(bg, desugar-scope-block(stmts, letrec-binds(lrbs)))
  end
end

fun simplify-let-bind(rebuild, l, bind, expr, lbs :: List<A.LetBind>) -> List<A.LetBind>:
  cases(A.Bind) bind:
    | s-bind(_,_,_,_) => rebuild(l, bind, expr) ^ link(_, lbs)
    | s-tuple-bind(lb, fields, as-name) =>
      {bound-expr; binding} = cases(Option) as-name:
        | none =>
          name = names.make-atom("tup")
          ann = A.a-tuple(lb, for map(f from fields):
              cases(A.Bind) f:
                | s-bind(_, _, _, a) => a
                | s-tuple-bind(_, _, _) => A.a-blank
              end
            end)
          {A.s-id(lb, name); rebuild(lb, A.s-bind(lb, false, name, ann), expr)}
        | some(b) =>
          binding = cases(A.Ann) b.ann:
            | a-blank =>
              # just create a tuple of the correct arity; leave the field annotations to be checked later
              ann = A.a-tuple(lb, for map(_ from fields): A.a-blank end)
              A.s-bind(b.l, b.shadows, b.id, ann)
            | else => b
          end
          {A.s-id(b.l, b.id); rebuild(l, binding, expr)}
      end
      for lists.fold_n(n from 0, shadow lbs from binding ^ link(_, lbs), f from fields):
        simplify-let-bind(rebuild, f.l, f, A.s-tuple-get(f.l, bound-expr, n, f.l), lbs)
      end
  end
end

fun add-let-binds(bg :: BindingGroup, lbs :: List<A.LetBind>, stmts :: List<A.Expr>) -> A.Expr:
  simplified-lbs = for fold(acc from empty, lb from lbs):
    cases(A.LetBind) lb:
      | s-let-bind(l, b, value) => simplify-let-bind(A.s-let-bind, l, b, value, acc)
      | s-var-bind(l, b, value) => simplify-let-bind(A.s-var-bind, l, b, value, acc)
    end
  end
  cases(BindingGroup) bg:
    | let-binds(binds) =>
      desugar-scope-block(stmts, let-binds(simplified-lbs + binds))
    | else =>
      bind-wrap(bg, desugar-scope-block(stmts, let-binds(simplified-lbs)))
  end
end

fun add-let-bind(bg :: BindingGroup, lb :: A.LetBind, stmts :: List<A.Expr>) -> A.Expr:
 add-let-binds(bg, [list: lb], stmts)
end

fun add-type-let-bind(bg :: BindingGroup, tlb :: A.TypeLetBind, stmts :: List<A.Expr>) -> A.Expr:
  cases(BindingGroup) bg:
    | type-let-binds(binds) =>
      desugar-scope-block(stmts, type-let-binds(link(tlb, binds)))
    | else =>
      bind-wrap(bg, desugar-scope-block(stmts, type-let-binds(link(tlb, empty))))
  end
end

fun desugar-scope-block(stmts :: List<A.Expr>, binding-group :: BindingGroup) -> A.Expr:
  doc: ```
       Treating stmts as a block, resolve scope.
       There should be no blocks left after this stage of the compiler pipeline.
       ```
  cases(List) stmts:
    | empty => raise("Should not get an empty block in desugar-scope-block")
    | link(f, rest-stmts) =>
      cases(A.Expr) f:
        | s-type(l, name, params, ann) =>
          add-type-let-bind(binding-group, A.s-type-bind(l, name, params, ann), rest-stmts)
        | s-let(l, bind, expr, _) =>
          add-let-bind(binding-group, A.s-let-bind(l, bind, expr), rest-stmts)
        | s-var(l, bind, expr) =>
          add-let-bind(binding-group, A.s-var-bind(l, bind, expr), rest-stmts)
        | s-rec(l, bind, expr) =>
          add-letrec-bind(binding-group, A.s-letrec-bind(l, bind, expr), rest-stmts)
        | s-fun(l, name, params, args, ann, doc, body, _check, blocky) =>
          add-letrec-bind(binding-group, A.s-letrec-bind(
              l,
              A.s-bind(l, false, A.s-name(l, name), A.a-blank),
              A.s-lam(l, name, params, args, ann, doc, body, _check, blocky)
            ), rest-stmts)
        | s-data-expr(l, name, namet, params, mixins, variants, shared, _check) =>
          fun b(loc, id :: String): A.s-bind(loc, false, A.s-name(loc, id), A.a-blank) end
          fun bn(loc, n :: A.Name): A.s-bind(loc, false, n, A.a-blank) end
          fun variant-binds(data-blob-id, v):
            vname = v.name
            checker-name = A.make-checker-name(vname)
            get-part = A.s-dot(v.l, data-blob-id, _)
            [list:
              A.s-letrec-bind(v.l, b(v.l, vname), get-part(vname)),
              A.s-letrec-bind(v.l, b(v.l, checker-name), get-part(checker-name))
            ]
          end
          blob-id = names.make-atom(name)
          data-expr = A.s-data-expr(l, name, namet, params, mixins, variants, shared, _check)
          bind-data = A.s-letrec-bind(l, bn(l, blob-id), data-expr)
          bind-data-pred = A.s-letrec-bind(l, b(l, A.make-checker-name(name)), A.s-dot(l, A.s-id-letrec(l, blob-id, true), name))
          all-binds = for fold(acc from [list: bind-data-pred, bind-data], v from variants):
            variant-binds(A.s-id-letrec(v.l, blob-id, true), v) + acc
          end
          add-letrec-binds(binding-group, all-binds, rest-stmts)
        | s-contract(l, name, ann) =>
          desugar-scope-block(rest-stmts, binding-group)
        | s-check(l, name, body, keyword) =>
          fun b(loc): A.s-bind(loc, false, A.s-underscore(l), A.a-blank) end
          add-letrec-binds(binding-group, [list: A.s-letrec-bind(l, b(l), A.s-check(l, name, body, keyword))], rest-stmts)
        | else =>
          cases(List) rest-stmts:
            | empty => bind-wrap(binding-group, f)
            | link(_, _) =>
              rest-stmt = desugar-scope-block(rest-stmts, let-binds(empty))
              shadow rest-stmts = cases(A.Expr) rest-stmt:
                | s-block(_, shadow stmts) => link(f, stmts)
                | else => [list: f, rest-stmt]
              end
              bind-wrap(binding-group, A.s-block(f.l, rest-stmts))
          end
      end
  end
where:
  dsb = desugar-scope-block(_, let-binds(empty))
  p = lam(str): PP.surface-parse(str, "test").block end
  d = A.dummy-loc
  b = lam(s): A.s-bind(d, false, A.s-name(d, s), A.a-blank) end
  id = lam(s): A.s-id(d, A.s-name(d, s)) end
  bk = lam(e): A.s-block(d, [list: e]) end
  bs = lam(str):
    dsb(p(str).stmts).visit(A.dummy-loc-visitor)
  end
  n = none
  thunk = lam(e): A.s-lam(d, "", [list: ], [list: ], A.a-blank, "", bk(e), n, false) end


  compare1 = A.s-let-expr(d, [list: A.s-let-bind(d, b("x"), A.s-num(d, 15)),
                                      A.s-let-bind(d, b("y"), A.s-num(d, 10))],
                        id("y"), false)
  dsb(p("x = 15 y = 10 y").stmts).visit(A.dummy-loc-visitor)
    is compare1

  dsb(p("x = 55 var y = 10 y").stmts).visit(A.dummy-loc-visitor)
    is A.s-let-expr(d, [list: A.s-let-bind(d, b("x"), A.s-num(d, 55)),
      A.s-var-bind(d, b("y"), A.s-num(d, 10))], id("y"), false)

  bs("x = 7 print(2) var y = 10 y") is
    A.s-let-expr(d, [list:A.s-let-bind(d, b("x"), A.s-num(d, 7))],
        A.s-block(d, [list:
            A.s-app(d, id("print"), [list:A.s-num(d, 2)]),
            A.s-let-expr(d, [list:A.s-var-bind(d, b("y"), A.s-num(d, 10))],
              id("y"), false)
        ]), false)

  prog = bs("fun f(): 4 end fun g(): 5 end f()")
  prog is A.s-letrec(d, [list:
            A.s-letrec-bind(d, b("f"), thunk(A.s-num(d, 4))),
            A.s-letrec-bind(d, b("g"), thunk(A.s-num(d, 5)))
          ],
          A.s-app(d, id("f"), [list: ]), false)

  p-s = lam(e): A.s-app(d, id("print"), [list: e]) end
  pretty = lam(e): e.tosource().pretty(80).join-str("\n") end

  prog2 = bs("print(1) fun f(): 4 end fun g(): 5 end fun h(): 6 end x = 3 print(x)")
  prog2 is A.s-block(d,
    [list: p-s(A.s-num(d, 1)),
      A.s-letrec(d, [list:
          A.s-letrec-bind(d, b("f"), thunk(A.s-num(d, 4))),
          A.s-letrec-bind(d, b("g"), thunk(A.s-num(d, 5))),
          A.s-letrec-bind(d, b("h"), thunk(A.s-num(d, 6)))
        ],
        A.s-let-expr(d, [list: A.s-let-bind(d, b("x"), A.s-num(d, 3))], p-s(id("x")), false),
        false)])

  dsb([list: prog2]) is prog2
  for each2(p1 from dsb(prog2.stmts).stmts, p2 from prog2.stmts):
    p1.visit(A.dummy-loc-visitor) is p2
  end

  prog3 = bs("print(x) x := 3 print(x)")
  prog3 is A.s-block(d,
    [list:
      p-s(id("x")),
      A.s-assign(d, A.s-name(d, "x"), A.s-num(d, 3)),
      p-s(id("x"))
    ])
  
  prog4 = bs("var x = 10 fun f(): 4 end f()")
  prog4
    is A.s-let-expr(d, [list:
      A.s-var-bind(d, b("x"), A.s-num(d, 10))
    ],
    A.s-letrec(d, [list:
        A.s-letrec-bind(d, b("f"), thunk(A.s-num(d, 4)))
      ],
      A.s-app(d, id("f"), [list: ]), false),
    false
    )

  #prog5 = bs("data List: empty | link(f, r) end empty")
  #prog5.stmts.length() is 1
  #the-let = prog5.stmts
  #the-let satisfies A.is-s-let-expr
  #the-let.binds.length() is 6 # ListB, emptyB, linkB, List, is-empty, is-link
  #the-let.binds.take(3).map(_.value) satisfies lists.all(lam(e): A.is-s-app(e) and (e._fun.id == "brander") end, _)
  #the-let.binds.drop(3).map(_.value) satisfies lists.all(lam(e): A.is-s-dot(e) and (e.field == "test") end, _)
  #the-letrec = the-let.body
  #the-letrec satisfies A.is-s-letrec
  #the-letrec.binds.length() is 4 # emptyDict, linkDict, empty, link

end

fun rebuild-fun(rebuild, visitor, l, name, params, args, ann, doc, body, _check, blocky):
  v-params = params.map(_.visit(visitor))
  v-ann = ann.visit(visitor)
  v-body = body.visit(visitor)
  v-check = visitor.option(_check)
  placeholder = A.s-str(l, "placeholder")
  {new-binds; new-body} = for fold(acc from {empty; v-body}, a from args):
    {new-binds; new-body} = acc
    lbs = simplify-let-bind(A.s-let-bind, a.l, a.visit(visitor), placeholder, empty).reverse()
    arg-bind = lbs.first
    shadow new-binds = arg-bind.b ^ link(_, new-binds)
    cases(List) lbs.rest:
      | empty => {new-binds; new-body}
      | link(_, _) => {new-binds; A.s-let-expr(a.l, lbs.rest, new-body, false)}
    end
  end  
  rebuild(l, name, v-params, new-binds.reverse(), v-ann, doc, new-body, v-check, blocky)
end

desugar-scope-visitor = A.default-map-visitor.{
  method s-block(self, l, stmts):
    desugar-scope-block(stmts.map(_.visit(self)), let-binds(empty))
  end,
  method s-let-expr(self, l, binds, body, blocky):
    v-body = body.visit(self)
    new-binds = for fold(new-binds from empty, b from binds):
      simplify-let-bind(A.s-let-bind, b.l, b.b.visit(self), b.value.visit(self), new-binds)
    end
    A.s-let-expr(l, new-binds.reverse(), v-body, blocky)
  end,
  method s-for(self, l, iterator, bindings, ann, body, blocky):
    v-iterator = iterator.visit(self)
    v-ann = ann.visit(self)
    v-body = body.visit(self)
    {new-binds; new-body} = for fold(acc from {empty; v-body}, b from bindings):
      {new-binds; new-body} = acc
      lbs = simplify-let-bind(A.s-let-bind, b.l, b.bind.visit(self), b.value.visit(self), empty).reverse()
      arg-bind = lbs.first
      shadow new-binds = A.s-for-bind(b.l, arg-bind.b, arg-bind.value) ^ link(_, new-binds)
      cases(List) lbs.rest:
        | empty => {new-binds; new-body}
        | link(_, _) => {new-binds; A.s-let-expr(b.l, lbs.rest, new-body, false)}
      end
    end
    A.s-for(l, v-iterator, new-binds.reverse(), v-ann, new-body, blocky)
  end,
  method s-cases-branch(self, l, pat-loc, name, args, body):
    v-body = body.visit(self)
    {new-binds; new-body} = for fold(acc from {empty; v-body}, b from args):
      {new-binds; new-body} = acc
      lbs = simplify-let-bind(A.s-let-bind, b.l, b.bind.visit(self), A.s-str(b.l, "placeholder"), empty).reverse()
      arg-bind = lbs.first
      shadow new-binds = A.s-cases-bind(b.l, b.field-type, arg-bind.b) ^ link(_, new-binds)
      cases(List) lbs.rest:
        | empty => {new-binds; new-body}
        | link(_, _) => {new-binds; A.s-let-expr(b.l, lbs.rest, new-body, false)}
      end
    end
    A.s-cases-branch(l, pat-loc, name, new-binds.reverse(), new-body)
  end,
  method s-fun(self, l, name, params, args, ann, doc, body, _check, blocky):
    rebuild-fun(A.s-fun, self, l, name, params, args, ann, doc, body, _check, blocky)
  end,
  method s-lam(self, l, name, params, args, ann, doc, body, _check, blocky):
    rebuild-fun(A.s-lam, self, l, name, params, args, ann, doc, body, _check, blocky)
  end,
  method s-method(self, l, name, params, args, ann, doc, body, _check, blocky):
    rebuild-fun(A.s-method, self, l, name, params, args, ann, doc, body, _check, blocky)
  end,
  method s-method-field(self, l, name, params, args, ann, doc, body, _check, blocky):
    rebuild-fun(A.s-method-field, self, l, name, params, args, ann, doc, body, _check, blocky)
  end
}

fun desugar-scope(prog :: A.Program, env :: C.CompileEnvironment):
  doc: ```
       Remove x = e, var x = e, tuple bindings, and fun f(): e end
       and turn them into explicit let and letrec expressions.
       Do this recursively through the whole program.
       Preconditions on prog:
         - well-formed
       Postconditions on prog:
         - contains no s-provide in headers
         - contains no s-let, s-var, s-data, s-tuple-bind
       ```
  cases(A.Program) prog:
    | s-program(l, _provide-raw, provide-types-raw, imports-raw, body) =>
      imports = imports-raw.map(lam(i): expand-import(i, env) end)
      str = A.s-str(l, _)
      prov = cases(A.Provide) resolve-provide(_provide-raw, body):
        | s-provide-none(_) => A.s-obj(l, [list: ])
        | s-provide(_, block) => block
        | else => raise("Should have been resolved away")
      end
      provides = resolve-type-provide(provide-types-raw, body)
      provt = cases(A.ProvideTypes) provides:
        | s-provide-types-none(_) => [list: ]
        | s-provide-types(_, anns) => anns
        | else => raise("Should have been resolve-typed away" + torepr(provides))
      end
      # TODO: Need to resolve provide-types here
      with-imports = cases(A.Expr) body:
        | s-block(l2, stmts) =>
          A.s-block(l2, desugar-toplevel-types(stmts))
        | else => A.s-block(l, desugar-toplevel-types([list: body]))
      end
      fun transform-toplevel-last(l2, last):
        A.s-module(l2, last, empty, empty, prov, provt, A.s-app(l2, A.s-dot(l2, U.checkers(l2), "results"), empty))
      end
      with-provides = cases(A.Expr) with-imports:
        | s-block(l2, stmts) =>
          last = stmts.last()
          cases(A.Expr) last:
            | s-type-let-expr(l3, binds, body2, blocky) =>
              inner-last = body2.stmts.last()
              A.s-block(l2,
                stmts.take(stmts.length() - 1) + [list:
                  A.s-type-let-expr(l3, binds,
                    A.s-block(body2.l, body2.stmts.take(body2.stmts.length() - 1)
                        + [list: transform-toplevel-last(l3, inner-last)]),
                    true)])
            | else =>
              A.s-block(l2, stmts.take(stmts.length() - 1) + [list: transform-toplevel-last(l2, last)])
          end
        | else => raise("Impossible")
      end

      A.s-program(l, A.s-provide-none(l), A.s-provide-types-none(l),
        imports, with-provides.visit(desugar-scope-visitor))
  end
  
where:
  d = A.dummy-loc
  b = lam(s): A.s-bind(d, false, A.s-name(d, s), A.a-blank) end
  id = lam(s): A.s-id(d, A.s-name(d, s)) end
  checks = A.s-app(d, A.s-dot(d, U.checkers(d), "results"), [list: ])
  str = A.s-str(d, _)
  ds = lam(prog): desugar-scope(prog, C.standard-builtins).visit(A.dummy-loc-visitor) end
  compare1 = A.s-program(d, A.s-provide-none(d), A.s-provide-types-none(d), [list: ],
        A.s-let-expr(d, [list:
            A.s-let-bind(d, b("x"), A.s-num(d, 10))
          ],
          A.s-module(d, id("nothing"), empty, empty, id("x"), [list:], checks), false)
      )
  # NOTE(joe): Explicit nothing here because we expect to have
  # had append-nothing-if-necessary called
  ds(PP.surface-parse("provide x end x = 10 nothing", "test")) is compare1
end



data ScopeBinding:
  | letrec-bind(loc, atom :: A.Name, ann :: A.Ann, expr :: Option<A.Expr>)
  | let-bind(loc, atom :: A.Name, ann :: A.Ann, expr :: Option<A.Expr>)
  | var-bind(loc, atom :: A.Name, ann :: A.Ann, expr :: Option<A.Expr>)
  | global-bind(loc, atom :: A.Name, expr :: Option<A.Expr>)
  | module-bind(loc, atom :: A.Name, mod :: A.ImportType, expr :: Option<A.Expr>)
end

data TypeBinding:
  | let-type-bind(loc, atom :: A.Name, ann :: Option<A.Ann>)
  | type-var-bind(loc, atom :: A.Name, ann :: Option<A.Ann>)
  | global-type-bind(loc, atom :: A.Name, ann :: Option<A.Ann>)
  | module-type-bind(loc, atom :: A.Name, mod :: A.ImportType, ann :: Option<A.Ann>)
end

fun scope-env-from-env(initial :: C.CompileEnvironment) block:
  acc = SD.make-mutable-string-dict()
  for each(name from initial.globals.values.keys-list()):
    acc.set-now(name, global-bind(S.builtin("pyret-builtin"), names.s-global(name), none))
  end
  acc.freeze()
where:
  scope-env-from-env(C.compile-env(C.globals([string-dict: "x", T.t-top(A.dummy-loc, false)], mtd), mtd))
    .get-value("x") is global-bind(S.builtin("pyret-builtin"), names.s-global("x"), none)
end

fun type-env-from-env(initial :: C.CompileEnvironment) block:
  acc = SD.make-mutable-string-dict()
  for each(name from initial.globals.types.keys-list()):
    acc.set-now(name, global-type-bind(S.builtin("pyret-builtin-type"), names.s-type-global(name), none))
  end
  acc.freeze()
end


fun resolve-names(p :: A.Program, initial-env :: C.CompileEnvironment):
  doc: ```
       Turn all s-names into s-atom or s-global
       Requires:
        1. desugar-scope
       Preconditions on p:
        -  Contains no s-block, s-let, s-var, s-data, s-rec
       Postconditions on p (in addition to preconditions):
        -  Contains no s-name in names
       ```
  var name-errors = [list: ]
  bindings = SD.make-mutable-string-dict()
  type-bindings = SD.make-mutable-string-dict()
  datatypes = SD.make-mutable-string-dict()

  fun make-anon-import-for(l, s, env, shadow bindings, b) block:
    atom = names.make-atom(s)
    bindings.set-now(atom.key(), b(atom))
    { atom: atom, env: env }
  end
  fun make-atom-for(name, is-shadowing, env, shadow bindings, make-binding):
    cases(A.Name) name block:
      | s-name(l, s) =>
        when env.has-key(s) and not(is-shadowing):
          old-loc = env.get-value(s).loc
          name-errors := link(C.shadow-id(s, l, old-loc), name-errors)
        end
        atom = names.make-atom(s)
        binding = make-binding(l, atom)
        bindings.set-now(atom.key(), binding)
        { atom: atom, env: env.set(s, binding) }
      | s-underscore(l) =>
        atom = names.make-atom("$underscore")
        bindings.set-now(atom.key(), make-binding(l, atom))
        { atom: atom, env: env }
      # NOTE(joe): an s-atom is pre-resolved to all its uses, so no need to add
      # it or do any more work.
      | s-atom(_, _) =>
        binding = make-binding(A.dummy-loc, name)
        # THIS LINE DOES NOTHING??
        # env.set(name.key(), binding)
        bindings.set-now(name.key(), binding)
        { atom: name, env: env }
      | else => raise("Unexpected atom type: " + torepr(name))
    end
  end
  fun update-type-binding-ann(atom, ann):
    if type-bindings.has-key-now(atom.key()):
      cases(TypeBinding) type-bindings.get-value-now(atom.key()):
        | let-type-bind(l, _, _) =>
          type-bindings.set-now(atom.key(), let-type-bind(l, atom, ann))
        | module-type-bind(l, _, imp, _) =>
          type-bindings.set-now(atom.key(), module-type-bind(l, atom, imp, ann))
        | global-type-bind(l, _, _) =>
          type-bindings.set-now(atom.key(), global-type-bind(l, atom, ann))
        | type-var-bind(l, _, _) =>
          type-bindings.set-now(atom.key(), type-var-bind(l, atom, ann))
      end
    else:
      print("No binding for " + torepr(atom))
    end
  end
  fun update-binding-expr(atom, expr):
    cases(Option) bindings.get-now(atom.key()):
      | none => nothing
      | some(sb) =>
        cases(ScopeBinding) sb:
          | letrec-bind(loc, _, ann, _) => bindings.set-now(atom.key(), letrec-bind(loc, atom, ann, expr))
          | let-bind(loc, _, ann, _) => bindings.set-now(atom.key(), let-bind(loc, atom, ann, expr))
          | var-bind(loc, _, ann, _) => bindings.set-now(atom.key(), var-bind(loc, atom, ann, expr))
          | global-bind(loc, _, _) => bindings.set-now(atom.key(), global-bind(loc, atom, expr))
          | module-bind(loc, _, imp, _) => bindings.set-now(atom.key(), module-bind(loc, atom, imp, expr))
        end
    end
  end
  fun resolve-letrec-binds(visitor, binds):
    {env; atoms} = for fold(acc from { visitor.env; empty }, b from binds):
      {env; atoms} = acc
      # TODO(joe): I think that b.b.ann.visit below could be wrong if
      # a letrec'd ID is used in a refinement within the same letrec,
      # so state may be necessary here
      atom-env = make-atom-for(b.b.id, b.b.shadows, env, bindings, letrec-bind(_, _, b.b.ann.visit(visitor), none))
      { atom-env.env; link(atom-env.atom, atoms) }
    end
    new-visitor = visitor.{env: env}
    visit-binds = for map2(b from binds, a from atoms.reverse()):
      cases(A.LetrecBind) b block:
        | s-letrec-bind(l2, bind, expr) =>
          new-bind = A.s-bind(l2, false, a, bind.ann.visit(visitor.{env: env}))
          visit-expr = expr.visit(new-visitor)
          update-binding-expr(a, some(visit-expr))
          A.s-letrec-bind(l2, new-bind, visit-expr)
      end
    end
    {
      visit-binds;
      new-visitor
    }
  end
  fun handle-id(env, l, id):
    cases(A.Name) id:
      | s-name(l2, s) =>
        if env.has-key(s):
          cases (ScopeBinding) env.get-value(s):
            | let-bind(_, atom, _, _) => atom
            | letrec-bind(_, atom, _, _) => atom
            | var-bind(_, atom, _, _, _) => atom
            | global-bind(_, atom, _) => atom
            | module-bind(_, _, _, _) => raise("Can't have a module-bound letrec or var id")
          end
        else:
          names.s-global(s)
        end
      | s-atom(_, _) => id
      | s-underscore(_) => id
      | else => raise("Wasn't expecting a non-s-name in resolve-names id: " + torepr(id))
    end
  end
  fun handle-ann(l, type-env, id):
    cases(A.Name) id:
      | s-name(_, s) =>
        if type-env.has-key(s):
          cases(TypeBinding) type-env.get-value(s):
            | global-type-bind(_, name, _) => A.a-name(l, name)
            | module-type-bind(_, name, _, _) => A.a-name(l, name)
            | let-type-bind(_, name, _) => A.a-name(l, name)
            | type-var-bind(_, name, _) => A.a-type-var(l, name)
          end
        else: A.a-name(l, names.s-type-global(s))
        end
      | else => A.a-name(l, id)
    end
  end
  
  fun handle-column-binds(column-binds :: A.ColumnBinds, visitor):
    env-and-binds = for fold(acc from { env: visitor.env, cbs: [list: ] }, cb from column-binds.binds):
        atom-env = make-atom-for(cb.id, cb.shadows, acc.env, bindings, let-bind(_, _, cb.ann, none))
        new-cb = A.s-bind(cb.l, cb.shadows, atom-env.atom, cb.ann.visit(visitor.{env: acc.env}))
        { env: atom-env.env, cbs: link(new-cb, acc.cbs) }
      end
    { column-binds: A.s-column-binds(column-binds.l, env-and-binds.cbs, column-binds.table.visit(visitor)),
               env: env-and-binds.env }
  end
      
  names-visitor = A.default-map-visitor.{
    env: scope-env-from-env(initial-env),
    type-env: type-env-from-env(initial-env),
    method s-module(self, l, answer, _, _, provided-vals, provided-types, checks):
      non-globals =
        for filter(k from self.env.keys-list()):
          sb = self.env.get-value(k)
          not(is-global-bind(sb) or is-module-bind(sb))
        end
      defined-vals = for map(key from non-globals): 
        id-exp = cases(ScopeBinding) self.env.get-value(key):
          | let-bind(_, atom, _, _) => A.s-id(l, atom)
          | letrec-bind(_, atom, _, _) => A.s-id-letrec(l, atom, true)
          | var-bind(_, atom, _, _) => A.s-id-var(l, atom)
          | module-bind(_, atom, _, _) => A.s-id(l, atom)
        end
        A.s-defined-value(key, id-exp)
      end
      non-global-types =
        for filter(k from self.type-env.keys-list()):
          tb = self.type-env.get-value(k)
          not(is-global-type-bind(tb) or is-module-type-bind(tb))
        end
      defined-types = for map(key from non-global-types):
        typ = cases(TypeBinding) self.type-env.get-value(key):
          | let-type-bind(_, atom, _) => A.a-name(l, atom)
          | type-var-bind(_, atom, _) => A.a-name(l, atom)
        end
        A.s-defined-type(key, typ)
      end
      A.s-module(l, answer.visit(self), defined-vals, defined-types, provided-vals.visit(self), provided-types.map(_.visit(self)), checks.visit(self))
    end,
    method s-program(self, l, _provide, _provide-types, imports, body) block:
      {imp-e; imp-te; imp-imps} = for fold(acc from { self.env; self.type-env; empty }, i from imports):
        {imp-e; imp-te; imp-imps} = acc
        cases(A.Import) i block:
          | s-import-complete(l2, vnames, tnames, file, name-vals, name-types) =>
            atom-env =
              if A.is-s-underscore(name-vals):
                make-anon-import-for(name-vals.l, "$import", imp-e, bindings, let-bind(l, _, A.a-any(l2), none))
              else:
                make-atom-for(name-vals, false, imp-e, bindings, let-bind(_, _, A.a-any(l2), none))
              end
            atom-env-t =
              if A.is-s-underscore(name-types):
                make-anon-import-for(name-types.l, "$import", imp-te, type-bindings, let-type-bind(l, _, none))
              else:
                make-atom-for(name-types, false, imp-te, type-bindings, let-type-bind(_, _, none))
              end
            {e; vn} = for fold(nv-v from {atom-env.env; empty}, v from vnames):
              {e; vn} = nv-v
              v-atom-env = make-atom-for(v, false, e, bindings, module-bind(_, _, file, none))
              { v-atom-env.env; link(v-atom-env.atom, vn) }
            end
            {te; tn} = for fold(nv-t from {atom-env-t.env; empty}, t from tnames):
              {te; tn} = nv-t
              t-atom-env = make-atom-for(t, false, te, type-bindings, module-type-bind(_, _, file, none))
              { t-atom-env.env; link(t-atom-env.atom, tn) }
            end
            new-header = A.s-import-complete(l2,
              vn,
              tn,
              file,
              atom-env.atom,
              atom-env-t.atom)
            update-binding-expr(atom-env.atom, some(new-header))
            update-type-binding-ann(atom-env-t.atom, some(new-header))
            { e; te; link(new-header, imp-imps) }
          | else => raise("Should only have s-import-complete when checking scope")
        end
      end
      visit-body = body.visit(self.{env: imp-e, type-env: imp-te})
      var vals = nothing
      var typs = nothing
      visit-body.visit(A.default-iter-visitor.{
        method s-module(_, _, _, dv, dt, _, _, _) block:
          vals := dv
          typs := dt
          true
        end
      })
      data-defs = for map(ddk from datatypes.keys-list-now()):
        dd = datatypes.get-value-now(ddk) 
        A.p-data(dd.l, dd.namet, none)
      end
      non-module-vals = for filter(vd from vals):
        binding = bindings.get-value-now(vd.value.id.key())
        not(is-some(binding.expr) and is-s-import-complete(binding.expr.value))
      end
      val-defs = for map(vd from non-module-vals):
        v-binding = bindings.get-value-now(vd.value.id.key())
        cases(ScopeBinding) v-binding:
          | letrec-bind(loc, atom, ann, expr) =>
            A.p-value(loc, atom, ann)
          | let-bind(loc, atom, ann, expr) =>
            A.p-value(loc, atom, ann)
          | var-bind(loc, atom, ann, expr) =>
            A.p-value(loc, atom, ann)
          | module-bind(loc, atom, mod, expr) =>
            A.p-value(loc, atom, A.a-any(loc))
          | else => raise("Shouldn't happen, defined-value is global: " + torepr(v-binding))
        end
      end
      non-module-defs = for filter(td from typs):
        t-binding = type-bindings.get-value-now(td.typ.id.key())
        cases(TypeBinding) t-binding:
          | let-type-bind(loc, atom :: A.Name, ann :: Option<A.Ann>) =>
            not(is-some(ann) and is-s-import-complete(ann.value))
          | else => true
        end
      end
      alias-defs = for map(td from non-module-defs):
        t-binding = type-bindings.get-value-now(td.typ.id.key())
        cases(TypeBinding) t-binding:
          | let-type-bind(loc, atom :: A.Name, ann :: Option<A.Ann>) =>
            A.p-alias(loc, atom, atom, none)
          | else => raise("Shouldn't happen, defined-alias is not let-bound type: " + torepr(t-binding))
        end
      end
      one-true-provide = A.s-provide-complete(
        l,
        val-defs,
        alias-defs,
        data-defs
      )
      
      A.s-program(l, one-true-provide, _provide-types, imp-imps.reverse(), visit-body)
    end,
    method s-type-let-expr(self, l, binds, body, blocky):
      {e; te; bs} = for fold(acc from { self.env; self.type-env; empty }, b from binds):
        {e; te; bs} = acc
        cases(A.TypeLetBind) b block:
          | s-type-bind(l2, name, params, ann) =>
            shadow acc = { env: e, te: te }
            new-types = for fold(shadow acc from {env: acc.te, atoms: empty}, param from params):
              atom-env = make-atom-for(param, false, acc.env, type-bindings, type-var-bind(_, _, none))
              { env: atom-env.env, atoms: link(atom-env.atom, acc.atoms) }
            end
            atom-env = make-atom-for(name, false, acc.te, type-bindings, let-type-bind(_, _, none))
            new-bind = A.s-type-bind(l2, atom-env.atom, new-types.atoms.reverse(), ann.visit(self.{env: e, type-env: new-types.env}))
            update-type-binding-ann(atom-env.atom, some(new-bind.ann))
            { e; atom-env.env; link(new-bind, bs) }

            #new-types = for fold(shadow acc from { e; te; empty }, param from params) block:
            #  atom-env = make-atom-for(param, false, acc.{1}, type-bindings, type-var-bind(_, _, none))
            #  { e; atom-env.env; link(atom-env.atom, acc.{2}) }
            #end
            #atom-env = make-atom-for(name, false, te, type-bindings, let-type-bind(_, _, none))
            #new-bind = A.s-type-bind(l2, atom-env.atom, new-types.{2}.reverse(), ann.visit(self.{env: acc.{0}, type-env: acc.{1}}))

            #update-type-binding-ann(atom-env.atom, some(new-bind.ann))
            #{ e; atom-env.env; link(new-bind, bs) }
          | s-newtype-bind(l2, name, tname) =>
            atom-env-t = make-atom-for(name, false, te, type-bindings, let-type-bind(_, _, none))
            # TODO(joe): type for name in newtype-bind?  Brander-binding?
            atom-env = make-atom-for(tname, false, e, bindings, let-bind(_, _, A.a-blank, none))
            new-bind = A.s-newtype-bind(l2, atom-env-t.atom, atom-env.atom)
            update-binding-expr(atom-env.atom, none)
            update-type-binding-ann(atom-env-t.atom, none)
            { atom-env.env; atom-env-t.env; link(new-bind, bs) }
        end
      end
      visit-body = body.visit(self.{env: e, type-env: te})
      A.s-type-let-expr(l, bs.reverse(), visit-body, blocky)
    end,
    method s-let-expr(self, l, binds, body, blocky):
      {e; bs; atoms} = for fold(acc from { self.env; empty; empty}, b from binds):
        {e; bs; atoms} = acc
        cases(A.LetBind) b block:
          | s-let-bind(l2, bind, expr) =>
            visited-ann = bind.ann.visit(self.{env: e})
            atom-env = make-atom-for(bind.id, bind.shadows, e, bindings, let-bind(_, _, visited-ann, none))
            visit-expr = expr.visit(self.{env: e})
            update-binding-expr(atom-env.atom, some(visit-expr))
            new-bind = A.s-let-bind(l2, A.s-bind(l2, bind.shadows, atom-env.atom, visited-ann), visit-expr)
            {
              atom-env.env;
              link(new-bind, bs);
              link(atom-env.atom, atoms)
               }
          | s-var-bind(l2, bind, expr) =>
            visited-ann = bind.ann.visit(self.{env: e})
            atom-env = make-atom-for(bind.id, bind.shadows, e, bindings, var-bind(_, _, visited-ann, none))
            visit-expr = expr.visit(self.{env: e})
            update-binding-expr(atom-env.atom, some(visit-expr))
            new-bind = A.s-var-bind(l2, A.s-bind(l2, bind.shadows, atom-env.atom, visited-ann), visit-expr)
            {
              atom-env.env;
              link(new-bind, bs);
              link(atom-env.atom, atoms)
            }
        end
      end
      visit-binds = bs.reverse()
      visit-body = body.visit(self.{env: e})
      A.s-let-expr(l, visit-binds, visit-body, blocky)
    end,
    method s-letrec(self, l, binds, body, blocky):
      {new-binds; new-visitor} = resolve-letrec-binds(self, binds)
      visit-body = body.visit(new-visitor)
      A.s-letrec(l, new-binds, visit-body, blocky)
    end,
    method s-for(self, l, iter, binds, ann, body, blocky):
      {env; fbs} = for fold(acc from { self.env; empty }, fb from binds):
        {env; fbs} = acc
        cases(A.ForBind) fb block:
          | s-for-bind(l2, bind, val) => 
            atom-env = make-atom-for(bind.id, bind.shadows, env, bindings, let-bind(_, _, bind.ann, none))
            new-bind = A.s-bind(bind.l, bind.shadows, atom-env.atom, bind.ann.visit(self.{env: env}))
            visit-val = val.visit(self)
            update-binding-expr(atom-env.atom, some(visit-val))
            new-fb = A.s-for-bind(l2, new-bind, visit-val)
            { atom-env.env; link(new-fb, fbs) }
        end
      end
      A.s-for(l, iter.visit(self), fbs.reverse(), ann.visit(self), body.visit(self.{env: env}), blocky)
    end,
    method s-for-do(self, l, from-clause, dos) block:
      {env; fb} = cases(A.ForBind) from-clause block:
        | s-for-bind(l2, bind, val) => 
          atom-env = make-atom-for(bind.id, bind.shadows, self.env, bindings, let-bind(_, _, bind.ann, none))
          new-bind = A.s-bind(bind.l, bind.shadows, atom-env.atom, bind.ann.visit(self))
          visit-val = val.visit(self)
          update-binding-expr(atom-env.atom, some(visit-val))
          new-fb = A.s-for-bind(l2, new-bind, visit-val)
          { atom-env.env; new-fb }
      end
      A.s-for-do(l, fb, dos.map(_.visit(self.{env: env})))
    end,
    method s-do(self, l, iter, binds, ann, body) block:
      {env; fbs} = for fold(acc from { self.env; [list: ] }, fb from binds):
        cases(A.ForBind) fb block:
          | s-for-bind(l2, bind, val) =>
            {env; fbs} = acc
            atom-env = make-atom-for(bind.id, bind.shadows, env, bindings, let-bind(_, _, bind.ann, none))
            new-bind = A.s-bind(bind.l, bind.shadows, atom-env.atom, bind.ann.visit(self.{env: env}))
            visit-val = val.visit(self)
            update-binding-expr(atom-env.atom, some(visit-val))
            new-fb = A.s-for-bind(l2, new-bind, visit-val)
            { atom-env.env; link(new-fb, acc.fbs) }
        end
      end
      A.s-do(l, iter.visit(self), fbs.reverse(), ann.visit(self), body.visit(self.{env: env}))
    end,
    method s-cases-branch(self, l, pat-loc, name, args, body):
      {env; atoms} = for fold(acc from { self.env; empty }, a from args.map(_.bind)):
        {env; atoms} = acc
        atom-env = make-atom-for(a.id, a.shadows, env, bindings, let-bind(_, _, a.ann.visit(self), none))
        { atom-env.env; link(atom-env.atom, atoms) }
      end
      new-args = for map2(a from args, at from atoms.reverse()):
        cases(A.CasesBind) a:
          | s-cases-bind(l2, typ, binding) =>
            cases(A.Bind) binding:
              | s-bind(l3, shadows, id, ann) =>
                A.s-cases-bind(l2, typ, A.s-bind(l3, false, at, ann.visit(self.{env: env})))
            end
        end
      end
      new-body = body.visit(self.{env: env})
      A.s-cases-branch(l, pat-loc, name, new-args, new-body)
    end,
    # s-singleton-cases-branch introduces no new bindings
    method s-data-expr(self, l, name, namet, params, mixins, variants, shared-members, _check) block:
      {env; atoms} = for fold(acc from { self.type-env; empty }, param from params):
        {env; atoms} = acc
        atom-env = make-atom-for(param, false, env, type-bindings, type-var-bind(_, _, none))
        { atom-env.env; link(atom-env.atom, atoms) }
      end
      with-params = self.{type-env: env}
      result = A.s-data-expr(l, name, namet, atoms.reverse(),
        mixins.map(_.visit(with-params)), variants.map(_.visit(with-params)),
        shared-members.map(_.visit(with-params)), with-params.option(_check))
      datatypes.set-now(namet.key(), result)
      result
    end,
    method s-lam(self, l, name, params, args, ann, doc, body, _check, blocky) block:
     {ty-env; ty-atoms} = for fold(acc from {self.type-env; empty }, param from params):
        {env; atoms} = acc
        atom-env = make-atom-for(param, false, env, type-bindings, type-var-bind(_, _, none))
        { atom-env.env; link(atom-env.atom, atoms) }
      end
      with-params = self.{type-env: ty-env}
      {env; atoms} = for fold(acc from { with-params.env; empty }, a from args):
        {env; atoms} = acc
        atom-env = make-atom-for(a.id, a.shadows, env, bindings, let-bind(_, _, a.ann.visit(with-params), none))
        { atom-env.env; link(atom-env.atom, atoms) }
      end
      new-args = for map2(a from args, at from atoms.reverse()):
        cases(A.Bind) a:
          | s-bind(l2, shadows, id, ann2) => A.s-bind(l2, false, at, ann2.visit(with-params))
        end
      end
      with-params-and-args = with-params.{env: env}
      new-body = body.visit(with-params-and-args)
      saved-name-errors = name-errors
      new-check = with-params.option(_check) # Maybe should be self?  Are any type params visible here?
      # Restore the errors to what they were. (_check has already been desugared,
      # so the programmer will see those errors, not the ones from here.)
      name-errors := saved-name-errors
      A.s-lam(l, name, ty-atoms.reverse(), new-args, ann.visit(with-params), doc, new-body, new-check, blocky)
    end,
    method s-method(self, l, name, params, args, ann, doc, body, _check, blocky):
      {ty-env; ty-atoms} = for fold(acc from {self.type-env; empty }, param from params):
        {env; atoms} = acc
        atom-env = make-atom-for(param, false, env, type-bindings, type-var-bind(_, _, none))
        { atom-env.env; link(atom-env.atom, atoms) }
      end
      with-params = self.{type-env: ty-env}
      {env; atoms} = for fold(acc from { with-params.env; empty }, a from args):
        {env; atoms} = acc
        atom-env = make-atom-for(a.id, a.shadows, env, bindings, let-bind(_, _, a.ann.visit(with-params), none))
        { atom-env.env; link(atom-env.atom, atoms) }
      end
      new-args = for map2(a from args, at from atoms.reverse()):
        cases(A.Bind) a:
          | s-bind(l2, shadows, id, ann2) => A.s-bind(l2, shadows, at, ann2.visit(with-params))
        end
      end
      new-body = body.visit(with-params.{env: env})
      new-check = with-params.option(_check)
      A.s-method(l, name, ty-atoms.reverse(), new-args, ann.visit(with-params), doc, new-body, new-check, blocky)
    end,
    method s-method-field(self, l, name, params, args, ann, doc, body, _check, blocky):
      {ty-env; ty-atoms} = for fold(acc from {self.type-env; empty }, param from params):
        {env; atoms} = acc
        atom-env = make-atom-for(param, false, env, type-bindings, type-var-bind(_, _, none))
        { atom-env.env; link(atom-env.atom, atoms) }
      end
      with-params = self.{type-env: ty-env}
      {env; atoms} = for fold(acc from { with-params.env; empty }, a from args):
        {env; atoms} = acc
        atom-env = make-atom-for(a.id, a.shadows, env, bindings, let-bind(_, _, a.ann.visit(with-params), none))
        { atom-env.env; link(atom-env.atom, atoms) }
      end
      new-args = for map2(a from args, at from atoms.reverse()):
        cases(A.Bind) a:
          | s-bind(l2, shadows, id, ann2) => A.s-bind(l2, shadows, at, ann2.visit(with-params))
        end
      end
      new-body = body.visit(with-params.{env: env})
      new-check = with-params.option(_check)
      A.s-method-field(l, name, ty-atoms.reverse(), new-args, ann.visit(with-params), doc, new-body, new-check, blocky)    end,
    method s-assign(self, l, id, expr):
      cases(A.Name) id:
        | s-name(l2, s) =>
          if self.env.has-key(s):
            bind = self.env.get-value(s)
            A.s-assign(l, bind.atom, expr.visit(self))
            # This used to examine bind in more detail, and raise an error if it wasn't a var-bind
            # but that's better suited for a later pass
          else:
            A.s-assign(l, id, expr.visit(self)) # TODO: Should this be a s-global after all?
          end
        | s-underscore(_) =>
          A.s-assign(l, id, expr.visit(self))
        | else => raise("Wasn't expecting a non-s-name in resolve-names for assignment: " + torepr(id))
      end
    end,
    # NOTE(joe): Since there's no syntactic difference between _uses_ of letrec-,
    # let-, and var-bound names, this case disambiguates based on known binding
    # information
    method s-id(self, l, id):
      cases(A.Name) id:
        | s-name(l2, s) =>
          cases(Option) self.env.get(s) block:
            | none =>
              when self.type-env.has-key(s):
                name-errors := link(C.type-id-used-as-value(l2, id), name-errors)
              end
              A.s-id(l2, names.s-global(s))
            | some(sb) =>
              cases (ScopeBinding) sb:
                | let-bind(_, atom, _, _) => A.s-id(l2, atom)
                | letrec-bind(_, atom, _, _) => A.s-id-letrec(l2, atom, false)
                | var-bind(_, atom, _, _) => A.s-id-var(l2, atom)
                | global-bind(_, atom, _) => A.s-id(l2, atom)
                | module-bind(_, atom, _, _) => A.s-id(l2, atom)
              end
          end
        | s-atom(_, _) => A.s-id(l, id)
        | s-underscore(_) => A.s-id(l, id)
        | else => raise("Wasn't expecting a non-s-name in resolve-names id: " + torepr(id))
      end
    end,
    method s-id-letrec(self, l, id, _): A.s-id-letrec(l, handle-id(self.env, l, id), false) end,
    method s-id-var(self, l, id): A.s-id-var(l, handle-id(self.env, l, id)) end,
    method s-variant-member(self, l, typ, bind):
      new-bind = cases(A.Bind) bind:
        | s-bind(l2, shadows, name, ann) =>
          atom-env = make-atom-for(name, true, self.env, bindings, let-bind(_, _, ann.visit(self), none))
          A.s-bind(l2, shadows, atom-env.atom, ann.visit(self))
      end
      A.s-variant-member(l, typ, new-bind)
    end,
    method s-bind(self, l, shadows, id, ann):
      cases(A.Name) id:
        | s-underscore(_) => A.s-bind(l, shadows, id, ann)
        | else => 
          raise("Should not reach non-underscore bindings in resolve-names: " + id.key() + " at " + torepr(l))
      end
    end,
    method a-blank(self): A.a-blank end,
    method a-any(self, l): A.a-any(l) end,
    method a-name(self, l, id): handle-ann(l, self.type-env, id) end,
    method a-arrow(self, l, args, ret, parens): A.a-arrow(l, args.map(_.visit(self)), ret.visit(self), parens) end,
    method a-method(self, l, args, ret): A.a-method(l, args.map(_.visit(self)), ret.visit(self)) end,
    method a-record(self, l, fields): A.a-record(l, fields.map(_.visit(self))) end,
    method a-app(self, l, ann, args): A.a-app(l, ann.visit(self), args.map(_.visit(self))) end,
    method a-pred(self, l, ann, exp): A.a-pred(l, ann.visit(self), exp.visit(self)) end,
    method a-dot(self, l, obj, field):
      obj-ann = handle-ann(l, self.type-env, obj)
      cases(A.Ann) obj-ann block:
        | a-name(_, name) => A.a-dot(l, name, field)
        | else =>
          name-errors := link(C.unexpected-type-var(l, obj), name-errors)
          A.a-blank
      end
    end,
    method a-field(self, l, name, ann): A.a-field(l, name, ann.visit(self)) end,
    method s-table-select(self, l, columns, table):
      A.s-table-select(l, columns.map(_.visit(self)), table.visit(self))
    end,
    method s-table-extend(self, l, column-binds, extensions):
      column-binds-and-env = handle-column-binds(column-binds, self)
      A.s-table-extend(l, column-binds-and-env.column-binds,
        extensions.map(_.visit(self.{env: column-binds-and-env.env})))
    end,
    method s-table-update(self, l, column-binds, updates):
      column-binds-and-env = handle-column-binds(column-binds, self)
      A.s-table-update(l, column-binds-and-env.column-binds,
        updates.map(_.visit(self.{env: column-binds-and-env.env})))
    end,
    method s-table-filter(self, l, column-binds, pred):
      column-binds-and-env = handle-column-binds(column-binds, self)
      A.s-table-filter(l, column-binds-and-env.column-binds,
        pred.visit(self.{env: column-binds-and-env.env}))
    end,
    method s-table-order(self, l, table, ordering):
      A.s-table-order(l, table.visit(self), ordering)
    end,
    method s-table-extent(self, l, column, table):
      A.s-table-extent(l, column.visit(self), table)
    end,
  }
  C.resolved(p.visit(names-visitor), name-errors, bindings, type-bindings, datatypes)
end

fun check-unbound-ids-bad-assignments(ast :: A.Program, resolved :: C.NameResolution, initial-env :: C.CompileEnvironment) block:
  var errors = [list: ] # THE MUTABLE LIST OF ERRORS
  bindings = resolved.bindings
  type-bindings = resolved.type-bindings
  fun add-error(err): errors := err ^ link(_, errors) end
  fun handle-id(id, loc):
    if A.is-s-underscore(id) block:
      add-error(C.underscore-as-expr(loc))
      false
    else if A.is-s-global(id) and initial-env.globals.values.has-key(id.toname()):
      false
    else if bindings.has-key-now(id.key()):
      false
    else:
      # print-error("Cannot find binding for " + id.key() + " at " + loc.format(true) + " in \n")
      # print-error("Bindings: " + torepr(bindings.keys-list-now()) + "\n")
      # print-error("Global values: " + torepr(initial-env.globals.values.keys-list()) + "\n")
      true
    end
  end
  ast.visit(A.default-iter-visitor.{
      method s-id(self, loc, id) block:
        when handle-id(id, loc):
          add-error(C.unbound-id(A.s-id(loc, id)))
        end
        true
      end,
      method s-id-var(self, loc, id) block:
        when handle-id(id, loc):
          add-error(C.unbound-id(A.s-id-var(loc, id)))
        end
        true
      end,
      method s-id-letrec(self, loc, id, safe) block:
        when handle-id(id, loc):
          add-error(C.unbound-id(A.s-id-letrec(loc, id, safe)))
        end
        true
      end,
      method s-assign(self, loc, id, value) block:
        id-k = id.key()
        if bindings.has-key-now(id-k):
          binding = bindings.get-value-now(id-k)
          when not(is-var-bind(binding)):
            add-error(C.bad-assignment(A.s-assign(loc, id, value), binding.loc))
          end
        else:
          add-error(C.unbound-var(id.toname(), loc))
        end
        value.visit(self)
      end,
      method a-name(self, loc, id) block:
        if A.is-s-underscore(id) block:
          add-error(C.underscore-as-ann(id.l))
        else if A.is-s-type-global(id) and initial-env.globals.types.has-key(id.toname()):
          nothing
        else if type-bindings.has-key-now(id.key()):
          nothing
        else:
          # print-error("Cannot find " + id.key() + " at " + loc.format(true) + " in:\n")
          # print-error("Type-bindings: " + torepr(type-bindings.keys-list-now()) + "\n")
          # print-error("Global types: " + torepr(initial-env.globals.types.keys-list()) + "\n")
          add-error(C.unbound-type-id(A.a-name(loc, id)))
          nothing
        end
        true
      end,
      method a-dot(self, loc, name, field) block:
        if A.is-s-underscore(name) block:
          add-error(C.underscore-as-ann(name.l))
        else if A.is-s-type-global(name) and initial-env.globals.types.has-key(name.toname()):
          # need to figure out how to read through the imports here, I think
          nothing
        else if type-bindings.has-key-now(name.key()):
          nothing
        else:
          # need to figure out how to read through the imports here, I think
          # print-error("Cannot find " + name.key() + " at " + loc.format(true) + " in:\n")
          # print-error("Type-bindings: " + torepr(type-bindings.keys-list-now()) + "\n")
          # print-error("Global types: " + torepr(initial-env.globals.types.keys-list()) + "\n")
          add-error(C.unbound-type-id(A.a-name(loc, name)))
          nothing
        end
        true
      end
    })
  errors
where:
  p = PP.surface-parse(_, "test")
  px = p("x")
  resolved = C.resolved(px, empty, [SD.mutable-string-dict:], [SD.mutable-string-dict:], [SD.mutable-string-dict:])
  unbound1 = check-unbound-ids-bad-assignments(px, resolved, C.standard-builtins)
  unbound1.length() is 1
end
