#include <ruby.h>
extern "C" {
#include <st.h>
}
#include <set>

typedef std::set<VALUE> ValueSet;

#define ST_FOREACH_FUNCTION(f) ((int (*)(ANYARGS))(f))

static ID id_parents;
static ID id_children;

static
int rs_each_related_i(VALUE obj, VALUE, ValueSet* result)
{ 
    result->insert(obj);
    return ST_CONTINUE;
}
static
int rs_each_related_sets_i(VALUE, VALUE value, ValueSet* result)
{
    st_foreach(RHASH(value)->tbl, ST_FOREACH_FUNCTION(rs_each_related_i), (st_data_t)result);
    return ST_CONTINUE;
}
static
void rs_each_related(VALUE set)
{
    ValueSet result;
    st_foreach(RHASH(set)->tbl, ST_FOREACH_FUNCTION(rs_each_related_sets_i), (st_data_t)&result);

    for (ValueSet::const_iterator it = result.begin(); it != result.end(); ++it)
	rb_yield_values(1, *it);
}
static
VALUE relation_support_each_parent(VALUE self)
{
    VALUE parents = rb_funcall(self, id_parents, 0);
    rs_each_related(parents);
    return self;
}
static
VALUE relation_support_each_child(VALUE self)
{
    VALUE children = rb_funcall(self, id_children, 0);
    rs_each_related(children);
    return self;
}

static VALUE relation_support_each_related(VALUE self)
{
    VALUE parents = rb_funcall(self, id_parents, 0);
    VALUE children = rb_funcall(self, id_children, 0);

    ValueSet result;
    st_foreach(RHASH(parents)->tbl, ST_FOREACH_FUNCTION(rs_each_related_sets_i), (st_data_t)&result);
    st_foreach(RHASH(children)->tbl, ST_FOREACH_FUNCTION(rs_each_related_sets_i), (st_data_t)&result);

    for (ValueSet::const_iterator it = result.begin(); it != result.end(); ++it)
	rb_yield_values(1, *it);
    return self;
}

extern "C" void Init_faster()
{
    VALUE mRoby = rb_define_module("Roby");
    VALUE mDirectedRelationSupport = rb_define_module_under(mRoby, "DirectedRelationSupport");
    rb_define_method(mDirectedRelationSupport, "each_parent_object", RUBY_METHOD_FUNC(relation_support_each_parent), 0);
    rb_define_method(mDirectedRelationSupport, "each_child_object", RUBY_METHOD_FUNC(relation_support_each_child), 0);
    rb_define_method(mDirectedRelationSupport, "each_related_object", RUBY_METHOD_FUNC(relation_support_each_related), 0);

    id_parents = rb_intern("parents");
    id_children = rb_intern("children");
}

