#ifndef RUBY_BGL_GRAPH_HH
#define RUBY_BGL_GRAPH_HH

#include <ruby.h>
#include <boost/graph/adjacency_list.hpp>
#include <set>
#include <boost/tuple/tuple.hpp>

extern VALUE bglModule;
extern VALUE bglGraph;
extern VALUE bglReverseGraph;
extern VALUE bglUndirectedGraph;
extern VALUE bglVertex;

/**********************************************************************
 * Definition of base C++ types
 */

struct EdgeProperty
{
    VALUE info;
    boost::default_color_type color; // needed by some algorithms

    EdgeProperty(VALUE info)
	: info(info) { }
};

struct RubyGraph : public boost::adjacency_list< boost::setS, boost::setS
		      , boost::bidirectionalS, VALUE, EdgeProperty>
{
    std::string name;
};
typedef std::map<VALUE, RubyGraph::vertex_descriptor>	graph_map;

inline RubyGraph& graph_wrapped(VALUE self)
{
    RubyGraph* object = 0;
    Data_Get_Struct(self, RubyGraph, object);
    return *object;
}

extern graph_map* vertex_descriptor_map(VALUE self, bool create);

/* Return the vertex_descriptor of +self+ in +graph+. The boolean is true if
 * +self+ is in graph, and false otherwise.
 */
inline std::pair<RubyGraph::vertex_descriptor, bool> 
rb_to_vertex(VALUE vertex, VALUE graph)
{
    graph_map* descriptors = vertex_descriptor_map(vertex, false);
    if (!descriptors)
        return std::make_pair(static_cast<void*>(0), false);
    graph_map::iterator it = descriptors->find(graph);
    if(it == descriptors->end())
	return std::make_pair(static_cast<void*>(0), false);
    else
	return std::make_pair(it->second, true);
}

/* Returns a range for all descriptors of +self+
 */
inline std::pair<graph_map::iterator, graph_map::iterator> vertex_descriptors(VALUE self)
{
    graph_map& descriptors = *vertex_descriptor_map(self, true);
    return make_pair(descriptors.begin(), descriptors.end());
}


namespace details
{
    template<typename Graph, bool direct> struct vertex_range;

    template<typename Graph>
    struct vertex_range<Graph, true>
    { 
	typedef typename Graph::adjacency_iterator iterator;
	typedef std::pair<iterator, iterator> range;

	static range get(RubyGraph::vertex_descriptor v, Graph& graph) 
	{ return adjacent_vertices(v, graph); }
	static range get(RubyGraph::vertex_descriptor v, Graph const& graph) 
	{ return adjacent_vertices(v, graph); }
    };

    template<typename Graph>
    struct vertex_range<Graph, false>
    { 
	typedef typename Graph::inv_adjacency_iterator iterator;
	typedef std::pair<iterator, iterator> range;

	static range get(RubyGraph::vertex_descriptor v, Graph& graph) 
	{ return inv_adjacent_vertices(v, graph); }
	static range get(RubyGraph::vertex_descriptor v, Graph const& graph) 
	{ return inv_adjacent_vertices(v, graph); }
    };
}

/** Iterates on all vertices in the range */
template <typename Range, typename F>
static bool for_each_value(Range range, RubyGraph& graph, F f)
{
    typedef typename Range::first_type Iterator;
    Iterator it, end;
    for (boost::tie(it, end) = range; it != end; )
    {
	VALUE value = graph[*it];
	++it;

	if (!f(value))
	    return false;
    }
    return true;
}

/** Iterates on each adjacent vertex of +v+ in +graph+ which are not yet in +already_seen+ */
template <typename Graph, bool direct>
static bool for_each_adjacent_uniq(RubyGraph::vertex_descriptor v, Graph const& graph, std::set<VALUE>& already_seen)
{
    typedef details::vertex_range<Graph, direct>	getter;
    typedef typename getter::iterator		        Iterator;

    Iterator it, end;
    for (boost::tie(it, end) = details::vertex_range<Graph, direct>::get(v, graph); it != end; )
    {
	VALUE related_object = graph[*it];
	bool inserted;
	boost::tie(boost::tuples::ignore, inserted) = already_seen.insert(related_object);
	++it;

	if (inserted)
	    rb_yield_values(1, related_object);
    }
    return true;
}

/* Iterates on all graphs +vertex+ is part of, calling f(RubyGraph&, vertex_descriptor). If the calling
 * function returns false, stop iteration here */
template<typename F>
static bool for_each_graph(VALUE vertex, F f)
{
    graph_map::iterator graph, graph_end;
    for (boost::tie(graph, graph_end) = vertex_descriptors(vertex); graph != graph_end;)
    {
	RubyGraph& g	    = graph_wrapped(graph->first);
	RubyGraph::vertex_descriptor v = graph->second;
	++graph;

	if (!f(v, g))
	    return false;
    }
    return true;
}

// Returns true if +v+ has either no child (if +direct+ is true) or no parents (if +direct+ is false)
template<typename Graph, bool direct>
bool vertex_has_adjacent_i(RubyGraph::vertex_descriptor v, Graph const& g)
{
    typedef typename details::vertex_range<Graph, direct> getter;
    typename getter::iterator begin, end;
    boost::tie(begin, end) = getter::get(v, g);
    return begin == end;
}

template<bool direct>
VALUE vertex_has_adjacent(int argc, VALUE* argv, VALUE self)
{
    VALUE graph = Qnil;
    rb_scan_args(argc, argv, "01", &graph);

    bool result;
    if (NIL_P(graph))
	result = for_each_graph(self, vertex_has_adjacent_i<RubyGraph, direct>);
    else
    {
	RubyGraph::vertex_descriptor v; bool exists;
	boost::tie(v, exists) = rb_to_vertex(self, graph);
	if (! exists)
	    return Qtrue;

	RubyGraph& g = graph_wrapped(graph);
	result = vertex_has_adjacent_i<RubyGraph, direct>(v, g);
    }
    return result ? Qtrue : Qfalse;
}


#endif

