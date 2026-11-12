#include <gtest/gtest.h>

#include "typeinfer/errors.hpp"
#include "typeinfer/printer.hpp"
#include "typeinfer/types.hpp"

using namespace typeinfer;

namespace {
ErrorKind unify_error(TypeStore& s, Type* a, Type* b) {
    try {
        s.unify(a, b);
    } catch (const TypeError& e) {
        return e.kind();
    }
    ADD_FAILURE() << "expected unification to fail";
    return ErrorKind::Unbound;
}
}  // namespace

TEST(Types, UnifyBindsVariables) {
    TypeStore s;
    Type* a = s.fresh_var(1);
    s.unify(a, s.int_type());
    EXPECT_EQ(TypeStore::repr(a), s.int_type());
}

TEST(Types, ConstructorMismatchIsUnify) {
    TypeStore s;
    EXPECT_EQ(unify_error(s, s.int_type(), s.bool_type()), ErrorKind::Unify);
    EXPECT_EQ(unify_error(s, s.list(s.int_type()), s.int_type()), ErrorKind::Unify);
}

TEST(Types, TupleArityMismatchIsUnify) {
    TypeStore s;
    Type* two[] = {s.int_type(), s.int_type()};
    Type* three[] = {s.int_type(), s.int_type(), s.int_type()};
    EXPECT_EQ(unify_error(s, s.tuple(two), s.tuple(three)), ErrorKind::Unify);
}

TEST(Types, OccursCheck) {
    TypeStore s;
    Type* a = s.fresh_var(1);
    EXPECT_EQ(unify_error(s, a, s.list(a)), ErrorKind::Occurs);
    Type* b = s.fresh_var(1);
    EXPECT_EQ(unify_error(s, s.fun(b, b), s.fun(s.fresh_var(1), s.list(b))), ErrorKind::Occurs);
}

TEST(Types, UnificationLowersLevels) {
    TypeStore s;
    Type* outer = s.fresh_var(1);
    Type* inner = s.fresh_var(3);
    s.unify(outer, s.list(inner));
    // `inner` is now reachable from a level-1 variable: it must not generalise
    // at level 1.
    EXPECT_FALSE(s.generalize(outer, 1));
}

TEST(Types, GeneralizeQuantifiesDeeperVariables) {
    TypeStore s;
    Type* a = s.fresh_var(2);
    Type* t = s.fun(a, a);
    EXPECT_TRUE(s.generalize(t, 1));
    EXPECT_EQ(TypeStore::repr(a)->level, TypeStore::kGenericLevel);
}

TEST(Types, InstantiateCopiesGenericVariablesConsistently) {
    TypeStore s;
    Type* a = s.fresh_var(2);
    Type* t = s.fun(a, a);
    s.generalize(t, 1);
    Type* i1 = s.instantiate(t, 1);
    Type* i2 = s.instantiate(t, 1);
    EXPECT_NE(i1, t);
    EXPECT_EQ(i1->args[0], i1->args[1]);   // same fresh variable twice
    EXPECT_NE(i1->args[0], i2->args[0]);   // different instantiations differ
    EXPECT_EQ(i1->args[0]->level, 1);
}

TEST(Types, InstantiateSharesSubtermsWithoutGenericVariables) {
    TypeStore s;
    Type* mono = s.fresh_var(1);
    Type* closed = s.list(mono);          // no generic variable inside
    Type* g = s.fresh_var(2);
    Type* t = s.fun(closed, g);
    s.generalize(t, 1);
    Type* i = s.instantiate(t, 1);
    EXPECT_EQ(i->args[0], closed);
}

TEST(Types, InstantiateKeepsDagSharing) {
    TypeStore s;
    Type* g = s.fresh_var(2);
    Type* shared = s.list(g);
    Type* two[] = {shared, shared};
    Type* t = s.tuple(two);
    s.generalize(t, 1);
    Type* i = s.instantiate(t, 1);
    EXPECT_EQ(i->args[0], i->args[1]);
}

TEST(Types, UnifyOfSharedDagsIsFast) {
    // Two doubling towers with 2^40 leaves when expanded; unification must
    // visit each distinct node once.
    TypeStore s;
    auto tower = [&] {
        Type* t = s.fresh_var(1);
        for (int i = 0; i < 40; ++i) {
            Type* two[] = {t, t};
            t = s.tuple(two);
        }
        return t;
    };
    Type* a = tower();
    Type* b = tower();
    s.unify(a, b);
    SUCCEED();
}

TEST(Types, DeepTypesAreHandled) {
    TypeStore s;
    Type* t = s.int_type();
    for (int i = 0; i < 3000; ++i) t = s.list(t);
    Type* v = s.fresh_var(1);
    s.unify(v, t);
    EXPECT_EQ(print_type(s, v).size(), 3 + 3000 * 5);
}
