#include <ruby.h>
#include "value_set.hh"
#include <algorithm>

using namespace std;

static VALUE cValueSet;
static ID id_new;

static ValueSet& get_wrapped_set(VALUE self)
{
    ValueSet* object = 0;
    Data_Get_Struct(self, ValueSet, object);
    return *object;
}

static void value_set_mark(ValueSet const* set) { std::for_each(set->begin(), set->end(), rb_gc_mark); }
static void value_set_free(ValueSet const* set) { delete set; }
static VALUE value_set_alloc(VALUE klass)
{
    ValueSet* cxx_set = new ValueSet;
    return Data_Wrap_Struct(klass, value_set_mark, value_set_free, cxx_set);
}
/* call-seq:
 *  set.empty?			    => true or false
 *
 * Checks if this set is empty
 */
static VALUE value_set_empty_p(VALUE self)
{ 
    ValueSet& set = get_wrapped_set(self);
    return set.empty() ? Qtrue : Qfalse;
}

/* call-seq:
 *  set.size			    => size
 *
 * Returns this set size
 */
static VALUE value_set_size(VALUE self)
{ 
    ValueSet& set = get_wrapped_set(self);
    return INT2NUM(set.size());
}


/* call-seq:
 *  set.each { |obj| ... }	    => set
 *
 */
static VALUE value_set_each(VALUE self)
{
    ValueSet& set = get_wrapped_set(self);
    for (ValueSet::iterator it = set.begin(); it != set.end();)
    {
	// Increment before calling yield() so that 
	// the current element can be deleted safely
	ValueSet::iterator this_it = it++;
	rb_yield(*this_it);
    }
    return self;
}

/* call-seq:
 *  set.delete_if { |obj| ... }		=> set
 *
 * Deletes all objects for which the block returns true
 */
static VALUE value_set_delete_if(VALUE self)
{
    ValueSet& set = get_wrapped_set(self);
    for (ValueSet::iterator it = set.begin(); it != set.end();)
    {
	// Increment before calling yield() so that 
	// the current element can be deleted safely
	ValueSet::iterator this_it = it++;
	bool do_delete = RTEST(rb_yield(*this_it));
	if (do_delete)
	    set.erase(this_it);
    }
    return self;
}

/* call-seq:
 *  set.include?(value)	    => true or false
 *
 * Checks if +value+ is in +set+
 */
static VALUE value_set_include_p(VALUE vself, VALUE vother)
{
    ValueSet const& self  = get_wrapped_set(vself);
    return self.find(vother) == self.end() ? Qfalse : Qtrue;
}

/* call-seq:
 *  set.to_value_set		    => set
 */
static VALUE value_set_to_value_set(VALUE self) { return self; }

/* call-seq:
 *  set.dup => other_set
 *
 * Duplicates this set, without duplicating the pointed-to objects
 */
static VALUE value_set_dup(VALUE vself, VALUE vother)
{
    ValueSet const& self  = get_wrapped_set(vself);
    VALUE vresult = rb_funcall2(cValueSet, id_new, 0, NULL);
    ValueSet& result = get_wrapped_set(vresult);
    for (ValueSet::const_iterator it = self.begin(); it != self.end(); ++it)
	result.insert(result.end(), *it);

    return vresult;
}

/* call-seq:
 *  set.include_all?(other)		=> true or false
 *
 * Checks if all elements of +other+ are in +set+
 */
static VALUE value_set_include_all_p(VALUE vself, VALUE vother)
{
    ValueSet const& self  = get_wrapped_set(vself);
    if (!RTEST(rb_obj_is_kind_of(vother, cValueSet)))
	rb_raise(rb_eArgError, "expected a ValueSet");
    ValueSet const& other = get_wrapped_set(vother);
    return std::includes(self.begin(), self.end(), other.begin(), other.end()) ? Qtrue : Qfalse;
}

/* call-seq:
 *  set.union(other)		=> union_set
 *  set | other			=> union_set
 *
 * Computes the union of +set+ and +other+. This operation is O(N + M)
 * is +other+ is a ValueSet
 */
static VALUE value_set_union(VALUE vself, VALUE vother)
{
    ValueSet const& self  = get_wrapped_set(vself);
    if (!RTEST(rb_obj_is_kind_of(vother, cValueSet)))
	rb_raise(rb_eArgError, "expected a ValueSet");
    ValueSet const& other = get_wrapped_set(vother);
    
    VALUE vresult = rb_funcall2(cValueSet, id_new, 0, NULL);
    ValueSet& result = get_wrapped_set(vresult);
    std::set_union(self.begin(), self.end(), other.begin(), other.end(), 
	    std::inserter(result, result.end()));
    return vresult;
}

/* call-seq:
 *  set.merge(other)		=> set
 *
 * Merges the elements of +other+ into +self+. If +other+ is a ValueSet, the operation is O(N + M)
 */
static VALUE value_set_merge(VALUE vself, VALUE vother)
{
    ValueSet& self  = get_wrapped_set(vself);
    if (!RTEST(rb_obj_is_kind_of(vother, cValueSet)))
	rb_raise(rb_eArgError, "expected a ValueSet");
    ValueSet const& other = get_wrapped_set(vother);
    
    self.insert(other.begin(), other.end());
    return vself;
}

/* call-seq:
 *   set.intersection!(other)	=> set
 *
 * Computes the intersection of +set+ and +other+, and modifies +self+ to be
 * that interesection. This operation is O(N + M) if +other+ is a ValueSet
 */
static VALUE value_set_intersection_bang(VALUE vself, VALUE vother)
{
    ValueSet& self  = get_wrapped_set(vself);
    if (!RTEST(rb_obj_is_kind_of(vother, cValueSet)))
	rb_raise(rb_eArgError, "expected a ValueSet");
    ValueSet const& other = get_wrapped_set(vother);
    
    ValueSet result;
    std::set_intersection(self.begin(), self.end(), other.begin(), other.end(), 
	    std::inserter(result, result.end()));
    self.swap(result);
    return vself;
}

/* call-seq:
 *   set.intersection(other)	=> intersection_set
 *   set & other		=> intersection_set
 *
 * Computes the intersection of +set+ and +other+. This operation
 * is O(N + M) if +other+ is a ValueSet
 */
static VALUE value_set_intersection(VALUE vself, VALUE vother)
{
    ValueSet const& self  = get_wrapped_set(vself);
    if (!RTEST(rb_obj_is_kind_of(vother, cValueSet)))
	rb_raise(rb_eArgError, "expected a ValueSet");
    ValueSet const& other = get_wrapped_set(vother);
    
    VALUE vresult = rb_funcall2(cValueSet, id_new, 0, NULL);
    ValueSet& result = get_wrapped_set(vresult);
    std::set_intersection(self.begin(), self.end(), other.begin(), other.end(), 
	    std::inserter(result, result.end()));
    return vresult;
}

/* call-seq:
 *  set.intersects?(other)	=> true or false
 *
 * Returns true if there is elements in +set+ that are also in +other
 */
static VALUE value_set_intersects(VALUE vself, VALUE vother)
{
    ValueSet const& self  = get_wrapped_set(vself);
    if (!RTEST(rb_obj_is_kind_of(vother, cValueSet)))
	rb_raise(rb_eArgError, "expected a ValueSet");
    ValueSet const& other = get_wrapped_set(vother);

    ValueSet::const_iterator 
	self_it   = self.begin(),
	self_end  = self.end(),
	other_it  = other.begin(),
	other_end = other.end();

    while(self_it != self_end && other_it != other_end)
    {
	if (*self_it < *other_it)
	    ++self_it;
	else if (*other_it < *self_it)
	    ++other_it;
	else
	    return Qtrue;
    }
    return Qfalse;
}

/* call-seq:
 *   set.difference!(other)	=> set
 *
 * Modifies +set+ so that it is the set of all elements of +set+ not in +other+.
 * This operation is O(N + M).
 */
static VALUE value_set_difference_bang(VALUE vself, VALUE vother)
{
    ValueSet& self  = get_wrapped_set(vself);
    if (!RTEST(rb_obj_is_kind_of(vother, cValueSet)))
	rb_raise(rb_eArgError, "expected a ValueSet");
    ValueSet const& other = get_wrapped_set(vother);
    
    ValueSet result;
    std::set_difference(self.begin(), self.end(), other.begin(), other.end(), 
	    std::inserter(result, result.end()));
    if (result.size() != self.size())
        self.swap(result);
    return vself;
}

/* call-seq:
 *   set.difference(other)	=> difference_set
 *   set - other		=> difference_set
 *
 * Computes the set of all elements of +set+ not in +other+. This operation
 * is O(N + M).
 */
static VALUE value_set_difference(VALUE vself, VALUE vother)
{
    ValueSet const& self  = get_wrapped_set(vself);
    if (!RTEST(rb_obj_is_kind_of(vother, cValueSet)))
	rb_raise(rb_eArgError, "expected a ValueSet");
    ValueSet const& other = get_wrapped_set(vother);
    
    VALUE vresult = rb_funcall2(cValueSet, id_new, 0, NULL);
    ValueSet& result = get_wrapped_set(vresult);
    std::set_difference(self.begin(), self.end(), other.begin(), other.end(), 
	    std::inserter(result, result.end()));
    return vresult;
}

/* call-seq:
 *  set.insert(value)		=> true or false
 * 
 * Inserts +value+ into +set+. Returns true if the value did not exist
 * in the set yet (it has actually been inserted), and false otherwise.
 * This operation is O(log N)
 */
static VALUE value_set_insert(VALUE vself, VALUE v)
{
    ValueSet& self  = get_wrapped_set(vself);
    bool exists = self.insert(v).second;
    return exists ? Qtrue : Qfalse;
}
/* call-seq:
 *  set.delete(value)		=> true or false
 * 
 * Removes +value+ from +set+. Returns true if the value did exist
 * in the set yet (it has actually been removed), and false otherwise.
 */
static VALUE value_set_delete(VALUE vself, VALUE v)
{
    ValueSet& self  = get_wrapped_set(vself);
    size_t count = self.erase(v);
    return count > 0 ? Qtrue : Qfalse;
}

/* call-seq:
 *  set == other		=> true or false
 *
 * Equality
 */
static VALUE value_set_equal(VALUE vself, VALUE vother)
{
    ValueSet const& self  = get_wrapped_set(vself);
    if (!RTEST(rb_obj_is_kind_of(vother, cValueSet)))
	return Qfalse;
    ValueSet const& other = get_wrapped_set(vother);
    return (self == other) ? Qtrue : Qfalse;
}

/* call-seq:
 *  set.clear			=> set
 *
 * Remove all elements of this set
 */
static VALUE value_set_clear(VALUE self)
{
    get_wrapped_set(self).clear();
    return self;
}

/* call-seq:
 *  set.initialize_copy(other)  => set
 *
 * Initializes +set+ with the values in +other+. Needed by #dup
 */
static VALUE value_set_initialize_copy(VALUE vself, VALUE vother)
{
    get_wrapped_set(vself) = get_wrapped_set(vother);
    return vself;
}







/* call-seq:
 *  to_value_set    => value_set
 *
 * Converts this array into a ValueSet object
 */
static VALUE array_to_value_set(VALUE self)
{
    VALUE vresult = rb_funcall2(cValueSet, id_new, 0, NULL);
    ValueSet& result = get_wrapped_set(vresult);

    long size  = RARRAY_LEN(self);
    for (int i = 0; i < size; ++i)
	result.insert(rb_ary_entry(self, i));

    return vresult;
}

static VALUE enumerable_to_value_set_i(VALUE i, VALUE* memo)
{
    ValueSet& result = *reinterpret_cast<ValueSet*>(memo);
    result.insert(i);
    return Qnil;
}

/* call-seq:
 *  enum.to_value_set		=> value_set
 *
 * Builds a ValueSet object from this enumerable
 */
static VALUE enumerable_to_value_set(VALUE self)
{
    VALUE vresult = rb_funcall2(cValueSet, id_new, 0, NULL);
    ValueSet& result = get_wrapped_set(vresult);

    rb_iterate(rb_each, self, RUBY_METHOD_FUNC(enumerable_to_value_set_i), reinterpret_cast<VALUE>(&result));
    return vresult;
}

/*
 * Document-class: ValueSet
 *
 * ValueSet is a wrapper around the C++ set<> template. set<> is an ordered container,
 * for which union(), intersection() and difference() is done in linear time. For performance
 * reasons, in the case of ValueSet, the values are ordered by their VALUE, which roughly is
 * their object_id.
 */

extern "C" void Init_value_set()
{
    rb_define_method(rb_mEnumerable, "to_value_set", RUBY_METHOD_FUNC(enumerable_to_value_set), 0);
    rb_define_method(rb_cArray, "to_value_set", RUBY_METHOD_FUNC(array_to_value_set), 0);

    cValueSet = rb_define_class("ValueSet", rb_cObject);
    id_new = rb_intern("new");
    rb_define_alloc_func(cValueSet, value_set_alloc);
    rb_define_method(cValueSet, "each", RUBY_METHOD_FUNC(value_set_each), 0);
    rb_define_method(cValueSet, "include?", RUBY_METHOD_FUNC(value_set_include_p), 1);
    rb_define_method(cValueSet, "include_all?", RUBY_METHOD_FUNC(value_set_include_all_p), 1);
    rb_define_method(cValueSet, "union", RUBY_METHOD_FUNC(value_set_union), 1);
    rb_define_method(cValueSet, "intersection", RUBY_METHOD_FUNC(value_set_intersection), 1);
    rb_define_method(cValueSet, "intersection!", RUBY_METHOD_FUNC(value_set_intersection_bang), 1);
    rb_define_method(cValueSet, "intersects?", RUBY_METHOD_FUNC(value_set_intersects), 1);
    rb_define_method(cValueSet, "difference", RUBY_METHOD_FUNC(value_set_difference), 1);
    rb_define_method(cValueSet, "difference!", RUBY_METHOD_FUNC(value_set_difference_bang), 1);
    rb_define_method(cValueSet, "insert", RUBY_METHOD_FUNC(value_set_insert), 1);
    rb_define_method(cValueSet, "merge", RUBY_METHOD_FUNC(value_set_merge), 1);
    rb_define_method(cValueSet, "delete", RUBY_METHOD_FUNC(value_set_delete), 1);
    rb_define_method(cValueSet, "==", RUBY_METHOD_FUNC(value_set_equal), 1);
    rb_define_method(cValueSet, "to_value_set", RUBY_METHOD_FUNC(value_set_to_value_set), 0);
    rb_define_method(cValueSet, "dup", RUBY_METHOD_FUNC(value_set_dup), 0);
    rb_define_method(cValueSet, "empty?", RUBY_METHOD_FUNC(value_set_empty_p), 0);
    rb_define_method(cValueSet, "size", RUBY_METHOD_FUNC(value_set_size), 0);
    rb_define_method(cValueSet, "clear", RUBY_METHOD_FUNC(value_set_clear), 0);
    rb_define_method(cValueSet, "initialize_copy", RUBY_METHOD_FUNC(value_set_initialize_copy), 1);
    rb_define_method(cValueSet, "delete_if", RUBY_METHOD_FUNC(value_set_delete_if), 0);
}


