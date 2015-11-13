#ifndef VALUE_SET_HH
#define VALUE_SET_HH

#include <set>
#include "ruby_allocator.hh"
typedef std::set<VALUE, std::less<VALUE>, ruby_allocator<VALUE> > ValueSet;

#endif

