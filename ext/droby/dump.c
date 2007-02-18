#include <ruby.h>
#include <intern.h>
#include <st.h>

static VALUE mRoby;
static VALUE mRobyDistributed;
static VALUE cDRbObject;
static VALUE cSet;
static VALUE cValueSet;
static ID id_droby_dump;
static ID id_append;

static VALUE droby_format(VALUE mod, VALUE object)
{
    if (RTEST(rb_obj_is_kind_of(object, cDRbObject)))
	return object;
    else if (RTEST(rb_respond_to(object, id_droby_dump)))
	return rb_funcall(object, id_droby_dump, 0);
    else if (RTEST(rb_funcall(mod, rb_intern("allowed_remote_access?"), 1, object)))
	return rb_class_new_instance(1, &object, cDRbObject);
    else
	return object;
}

static VALUE array_dump_element(VALUE element, VALUE result)
{   rb_ary_push(result, droby_format(mRobyDistributed, element));
    return Qnil; }
static VALUE array_droby_dump(VALUE self)
{
    VALUE  result = rb_ary_new();
    rb_iterate(rb_each, self, array_dump_element, result);
    return result;
}

static int hash_dump_element(VALUE key, VALUE value, VALUE result)
{
    rb_hash_aset(result, key, droby_format(mRobyDistributed, value));
    return ST_CONTINUE;
}
static VALUE hash_droby_dump(VALUE self)
{
    VALUE  result = rb_hash_new();
    rb_hash_foreach(self, hash_dump_element, result);
    return result;
}


static VALUE appendable_dump_element(VALUE value, VALUE result)
{
    rb_funcall(result, id_append, 1, droby_format(mRobyDistributed, value));
    return Qnil;
}
static VALUE set_droby_dump(VALUE self)
{
    VALUE result = rb_class_new_instance(0, 0, cSet);
    rb_iterate(rb_each, self, appendable_dump_element, result);
    return result;
}
static VALUE value_set_droby_dump(VALUE self)
{
    VALUE result = rb_class_new_instance(0, 0, cValueSet);
    rb_iterate(rb_each, self, appendable_dump_element, result);
    return result;
}

void Init_droby()
{
    mRoby            = rb_define_module("Roby");
    mRobyDistributed = rb_define_module_under(mRoby, "Distributed");
    cDRbObject = rb_const_get(rb_cObject, rb_intern("DRbObject"));
    cValueSet  = rb_const_get(rb_cObject, rb_intern("ValueSet"));
    cSet       = rb_const_get(rb_cObject, rb_intern("Set"));

    rb_define_singleton_method(mRobyDistributed, "format", droby_format, 1);

    id_droby_dump = rb_intern("droby_dump");
    id_append = rb_intern("<<");
    rb_define_method(rb_cArray , "droby_dump" , array_droby_dump     , 0);
    rb_define_method(rb_cHash  , "droby_dump" , hash_droby_dump      , 0);
    rb_define_method(cSet      , "droby_dump" , set_droby_dump       , 0);
    rb_define_method(cValueSet , "droby_dump" , value_set_droby_dump , 0);
}

