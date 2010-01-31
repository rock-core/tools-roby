#include <ruby.h>
#include <ruby/intern.h>
#include <ruby/st.h>
#include <set>

static VALUE mRoby;
static VALUE mRobyDistributed;
static VALUE cDRbObject;
static VALUE cSet;
static VALUE cValueSet;
static ID id_droby_dump;
static ID id_remote_id;
static ID id_append;

/* 
 * Document-class: Roby::Distributed
 */

/* call-seq:
 *   format(object, peer) => formatted_object
 *
 * Formats +object+ so that it is ready to be dumped by Marshal.dump for
 * sending to +peer+. This means that if the object has a droby_dump method, it
 * is called to get a marshallable object which represents +object+. Moreover,
 * if +peer+ responds to #incremental_dump?(object), this is called to
 * determine wether a full dump is required or if sending a
 * Roby::Distributed::RemoteID for remote reference is enough.
 *
 * If the object is not a DRbObject and does not define a #droby_dump method,
 * it is proxied through a DRbObject if it present in
 * Distributed.allow_remote_access. Otherwise, we will try to dump it as-is.
 */
static VALUE droby_format(int argc, VALUE* argv, VALUE self)
{
    VALUE object, destination;
    rb_scan_args(argc, argv, "11", &object, &destination);

    if (RTEST(rb_obj_is_kind_of(object, cDRbObject)))
	return object;

    if (RTEST(rb_respond_to(object, id_droby_dump)))
    {
	if (!NIL_P(destination) && RTEST(rb_funcall(destination, rb_intern("incremental_dump?"), 1, object)))
	    return rb_funcall(object, id_remote_id, 0);
	return rb_funcall(object, id_droby_dump, 1, destination);
    }

    VALUE remote_access = rb_iv_get(self, "@allowed_remote_access");
    int i;
    for (i = 0; i < RARRAY_LEN(remote_access); ++i)
    {
	if (rb_obj_is_kind_of(object, RARRAY_PTR(remote_access)[i]))
	    return rb_class_new_instance(1, &object, cDRbObject);
    }

    return object;
}

typedef struct DROBY_DUMP_ITERATION_ARG
{
    VALUE result;
    VALUE dest;
} DROBY_DUMP_ITERATION_ARG;

static VALUE array_dump_element(VALUE element, DROBY_DUMP_ITERATION_ARG* arg)
{   
    VALUE args[2] = { element, arg->dest };
    rb_ary_push(arg->result, droby_format(2, args, mRobyDistributed));
    return Qnil; 
}

// call-seq:
//   droby_dump(dest) => dumped_array
// 
// Creates a copy of this Array with all its values formatted for marshalling
// using Distributed.format.
static VALUE array_droby_dump(VALUE self, VALUE dest)
{
    VALUE result = rb_ary_new();
    struct RArray* array = RARRAY(self);
    int i;

    VALUE el[2] = { Qnil, dest };
    for (i = 0; i < RARRAY_LEN(array); ++i)
    {
	el[0] = RARRAY_PTR(array)[i];
	rb_ary_push(result, droby_format(2, el, mRobyDistributed));
    }

    return result;
}

static int hash_dump_element(VALUE key, VALUE value, DROBY_DUMP_ITERATION_ARG* arg)
{
    VALUE args_key[2] = { key, arg->dest };
    key = droby_format(2, args_key, mRobyDistributed);
    VALUE args_value[2] = { value, arg->dest };
    value = droby_format(2, args_value, mRobyDistributed);
    rb_hash_aset(arg->result, key, value);
    return ST_CONTINUE;
}

// call-seq:
//   droby_dump => dumped_hash
// 
// Creates a copy of this Hash with all its values formatted for marshalling
// using Distributed.format. The keys are not modified.
static VALUE hash_droby_dump(VALUE self, VALUE dest)
{
    DROBY_DUMP_ITERATION_ARG arg = { rb_hash_new(), dest };
    rb_hash_foreach(self, (int(*)(ANYARGS)) hash_dump_element, (VALUE)&arg);
    return arg.result;
}

static VALUE appendable_dump_element(VALUE value, DROBY_DUMP_ITERATION_ARG* arg)
{
    VALUE args[2] = { value, arg->dest };
    rb_funcall(arg->result, id_append, 1, droby_format(2, args, mRobyDistributed));
    return Qnil;
}

// Creates a copy of this Set with all its values formatted for marshalling
// using Distributed.format
static VALUE set_droby_dump(VALUE self, VALUE dest)
{
    DROBY_DUMP_ITERATION_ARG arg = { rb_class_new_instance(0, 0, cSet), dest };
    rb_iterate(rb_each, self, RUBY_METHOD_FUNC(appendable_dump_element), (VALUE)&arg);
    return arg.result;
}

// Creates a copy of this ValueSet with all its values formatted for
// marshalling using Distributed.format
static VALUE value_set_droby_dump(VALUE self, VALUE dest)
{
    VALUE result = rb_class_new_instance(0, 0, cValueSet);
    std::set<VALUE>* result_set;
    Data_Get_Struct(result, std::set<VALUE>, result_set);

    std::set<VALUE> const * source_set;
    Data_Get_Struct(self, std::set<VALUE>, source_set);

    VALUE el[2] = { Qnil, dest };
    for (std::set<VALUE>::const_iterator it = source_set->begin(); it != source_set->end(); ++it)
    {
	el[0] = *it;
	result_set->insert(droby_format(2, el, mRobyDistributed));
    }

    return result;
}

extern "C" void Init_roby_marshalling()
{
    id_droby_dump = rb_intern("droby_dump");
    id_remote_id = rb_intern("remote_id");
    id_append = rb_intern("<<");
    
    cDRbObject = rb_const_get(rb_cObject, rb_intern("DRbObject"));
    cValueSet  = rb_const_get(rb_cObject, rb_intern("ValueSet"));
    cSet       = rb_const_get(rb_cObject, rb_intern("Set"));

    /* */
    mRoby            = rb_define_module("Roby");
    /* */
    mRobyDistributed = rb_define_module_under(mRoby, "Distributed");

    rb_define_method(rb_cArray , "droby_dump" , RUBY_METHOD_FUNC(array_droby_dump)     , 1);
    rb_define_method(rb_cHash  , "droby_dump" , RUBY_METHOD_FUNC(hash_droby_dump)      , 1);
    rb_define_method(cSet      , "droby_dump" , RUBY_METHOD_FUNC(set_droby_dump)       , 1);
    rb_define_method(cValueSet , "droby_dump" , RUBY_METHOD_FUNC(value_set_droby_dump) , 1);

    rb_define_singleton_method(mRobyDistributed, "format", RUBY_METHOD_FUNC(droby_format), -1);

}

