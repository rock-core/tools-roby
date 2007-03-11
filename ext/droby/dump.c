#include <ruby.h>
#include <intern.h>
#include <st.h>

static VALUE mRoby;
static VALUE mRobyDistributed;
static VALUE cDRbObject;
static VALUE cSet;
static VALUE cValueSet;
static ID id_droby_dump;
static ID id_drb_object;
static ID id_append;

/* call-seq:
 *   format(object, partial_dumps = nil) => formatted_object
 *
 * Formats +object+ so that it is ready to be dumped by Marshal.dump in the
 * dRoby protocol. This means that if the object has a droby_dump method, it 
 * is called to get a marshallable object which represents +object+. If
 * +partial_dumps+ is non-nil, it is supposed to be a collection of objects for
 * which we should only send a DRbObject instead of calling #droby_dump.
 *
 * If the object is not a DRbObject and does not define a #droby_dump method,
 * it is proxied through a DRbObject if it has been allowed by
 * Distributed.allow_remote_access. Otherwise, we will try to dump it as-is.
 */
static VALUE droby_format(int argc, VALUE* argv, VALUE self)
{
    VALUE object, partial;
    rb_scan_args(argc, argv, "11", &object, &partial);

    if (RTEST(rb_obj_is_kind_of(object, cDRbObject)))
	return object;

    if (RTEST(rb_respond_to(object, id_droby_dump)))
    {
	if (!NIL_P(partial) && RTEST(rb_funcall(partial, rb_intern("include?"), 1, object)))
	    return rb_funcall(object, id_drb_object, 0);
	return rb_funcall(object, id_droby_dump, 0);
    }

    VALUE remote_access = rb_iv_get(self, "@allowed_remote_access");
    int i;
    for (i = 0; i < RARRAY(remote_access)->len; ++i)
    {
	if (rb_obj_is_kind_of(object, RARRAY(remote_access)->ptr[i]))
	{
	    if (RTEST(rb_respond_to(object, id_drb_object)))
		return rb_funcall(object, id_drb_object, 0);
	    return rb_class_new_instance(1, &object, cDRbObject);
	}
    }

    return object;
}

static VALUE array_dump_element(VALUE element, VALUE result)
{   rb_ary_push(result, droby_format(1, &element, mRobyDistributed));
    return Qnil; }

/* call-seq:
 *   droby_dump => dumped_array
 *
 * Creates a copy of this Array with all its values formatted for marshalling
 * using Distributed.format.
 */
static VALUE array_droby_dump(VALUE self)
{
    VALUE  result = rb_ary_new();
    rb_iterate(rb_each, self, array_dump_element, result);
    return result;
}

static int hash_dump_element(VALUE key, VALUE value, VALUE result)
{
    rb_hash_aset(result, key, droby_format(1, &value, mRobyDistributed));
    return ST_CONTINUE;
}

/* call-seq:
 *   droby_dump => dumped_hash
 *
 * Creates a copy of this Hash with all its values formatted for marshalling
 * using Distributed.format. The keys are not modified.
 */
static VALUE hash_droby_dump(VALUE self)
{
    VALUE  result = rb_hash_new();
    rb_hash_foreach(self, hash_dump_element, result);
    return result;
}

static VALUE appendable_dump_element(VALUE value, VALUE result)
{
    rb_funcall(result, id_append, 1, droby_format(1, &value, mRobyDistributed));
    return Qnil;
}

/* call-seq:
 *   droby_dump => dumped_set
 *
 * Creates a copy of this Set with all its values formatted for marshalling
 * using Distributed.format
 */
static VALUE set_droby_dump(VALUE self)
{
    VALUE result = rb_class_new_instance(0, 0, cSet);
    rb_iterate(rb_each, self, appendable_dump_element, result);
    return result;
}

/* call-seq:
 *   droby_dump => dumped_set
 *
 * Creates a copy of this ValueSet with all its values formatted for
 * marshalling using Distributed.format
 */
static VALUE value_set_droby_dump(VALUE self)
{
    VALUE result = rb_class_new_instance(0, 0, cValueSet);
    rb_iterate(rb_each, self, appendable_dump_element, result);
    return result;
}

void Init_droby()
{
    id_droby_dump = rb_intern("droby_dump");
    id_drb_object = rb_intern("drb_object");
    id_append = rb_intern("<<");
    
    mRoby            = rb_define_module("Roby");
    mRobyDistributed = rb_define_module_under(mRoby, "Distributed");
    cDRbObject = rb_const_get(rb_cObject, rb_intern("DRbObject"));
    cValueSet  = rb_const_get(rb_cObject, rb_intern("ValueSet"));
    cSet       = rb_const_get(rb_cObject, rb_intern("Set"));

    rb_define_singleton_method(mRobyDistributed, "format", droby_format, -1);

    rb_define_method(rb_cArray , "droby_dump" , array_droby_dump     , 0);
    rb_define_method(rb_cHash  , "droby_dump" , hash_droby_dump      , 0);
    rb_define_method(cSet      , "droby_dump" , set_droby_dump       , 0);
    rb_define_method(cValueSet , "droby_dump" , value_set_droby_dump , 0);
}

