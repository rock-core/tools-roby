#include <ruby.h>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/depth_first_search.hpp>
#include <boost/static_assert.hpp>
#include <boost/bind.hpp>
#include <boost/graph/reverse_graph.hpp>
#include <boost/iterator/transform_iterator.hpp>
#include <boost/iterator/filter_iterator.hpp>

#include <functional>
#include <iostream>

static VALUE utilrbValueSet;
static ID id_new;

using namespace boost;
using namespace std;

/**********************************************************************
 *  Definition of base C++ types
 */

typedef adjacency_list< boost::setS, boost::setS
		      , boost::bidirectionalS, VALUE, VALUE>	BGLGraph;

typedef BGLGraph::vertex_iterator	vertex_iterator;
typedef BGLGraph::vertex_descriptor	vertex_descriptor;
typedef BGLGraph::edge_iterator		edge_iterator;
typedef BGLGraph::edge_descriptor	edge_descriptor;

// This is highly GCC-specific ...
BOOST_STATIC_ASSERT(( boost::is_pointer<vertex_descriptor>::value ));
static vertex_descriptor rb_to_vertex_descriptor(VALUE descriptor)
{ return reinterpret_cast<vertex_descriptor>(descriptor & ~((VALUE)0x1)); }
static VALUE vertex_descriptor_to_rb(vertex_descriptor descriptor)
{ 
    VALUE v = reinterpret_cast<VALUE>(descriptor);
    assert(! (v & 0x1));
    return v | 0x1;
}


/* A Graph => vertex_descriptor map used in BGL::Vertex to keep
 * association between the ruby object and the graphs it is included
 * in
 */
typedef map<VALUE, vertex_descriptor>	graph_map;

static graph_map& vertex_descriptor_map(VALUE self);
static pair<vertex_descriptor, bool> rb_to_vertex(VALUE vertex, VALUE graph);

namespace details
{
    template<typename Graph, bool direct> struct vertex_range;

    template<typename Graph>
    struct vertex_range<Graph, true>
    { 
	typedef typename Graph::adjacency_iterator iterator;
	typedef pair<iterator, iterator> range;

	static range get(vertex_descriptor v, Graph& graph) 
	{ return adjacent_vertices(v, graph); }
	static range get(vertex_descriptor v, Graph const& graph) 
	{ return adjacent_vertices(v, graph); }
    };

    template<typename Graph>
    struct vertex_range<Graph, false>
    { 
	typedef typename Graph::inv_adjacency_iterator iterator;
	typedef pair<iterator, iterator> range;

	static range get(vertex_descriptor v, Graph& graph) 
	{ return inv_adjacent_vertices(v, graph); }
	static range get(vertex_descriptor v, Graph const& graph) 
	{ return inv_adjacent_vertices(v, graph); }
    };

    // Reverse graphs do not have an adjacency_iterator
    template<typename Graph>
    struct vertex_range< reverse_graph<Graph, Graph&>, false>
    {
	typedef typename Graph::adjacency_iterator iterator;
	typedef pair<iterator, iterator> range;

	static range get(vertex_descriptor v, reverse_graph<Graph, Graph&> const& graph) 
	{ return adjacent_vertices(v, graph.m_g); }
    };

    template<typename Graph>
    struct vertex_range< reverse_graph<Graph, Graph const&>, false>
    {
	typedef typename Graph::adjacency_iterator iterator;
	typedef pair<iterator, iterator> range;

	static range get(vertex_descriptor v, reverse_graph<Graph, Graph const&> const& graph) 
	{ return adjacent_vertices(v, graph.m_g); }
    };
}


/**********************************************************************
 *  BGL::Graph
 */


template <typename descriptor> static 
void graph_mark_object_property(BGLGraph& graph, descriptor object)
{ 
    VALUE value = graph[object];
    if (! NIL_P(value))
	rb_gc_mark(value); 
}

static 
void graph_mark(BGLGraph* graph) { 
    { vertex_iterator it, end;
	for (tie(it, end) = vertices(*graph); it != end; ++it)
	    graph_mark_object_property<vertex_descriptor>(*graph, *it);
    }

    { edge_iterator it, end;
	for (tie(it, end) = edges(*graph); it != end; ++it)
	    graph_mark_object_property<edge_descriptor>(*graph, *it);
    }
}

static void graph_free(BGLGraph* graph) { delete graph; }
static VALUE graph_alloc(VALUE klass)
{
    BGLGraph* graph = new BGLGraph;
    VALUE rb_graph = Data_Wrap_Struct(klass, graph_mark, graph_free, graph);
    return rb_graph;
}

BGLGraph& graph_wrapped(VALUE self)
{
    BGLGraph* object = 0;
    Data_Get_Struct(self, BGLGraph, object);
    return *object;
}

/*
 * call-seq:
 *    graph.each_vertex { |vertex| ... }     => graph
 *
 * Iterates on all vertices in +graph+.
 */
static
VALUE graph_each_vertex(VALUE self)
{
    BGLGraph& graph = graph_wrapped(self);

    vertex_iterator begin, end;
    tie(begin, end) = vertices(graph);

    for (vertex_iterator it = begin; it != end;)
    {
	VALUE vertex = graph[*it];
	++it;
	rb_yield(vertex);
    }
    return self;
}

/*
 * call-seq:
 *   graph.vertex_data(descriptor)		    => value
 *
 * Returns the vertex object associated with +descriptor+.
 */
static
VALUE graph_vertex_data(VALUE self, VALUE rb_descriptor)
{
    BGLGraph& graph = graph_wrapped(self);
    vertex_descriptor descriptor = rb_to_vertex_descriptor(rb_descriptor);
    return graph[descriptor];

}

/*
 * call-seq:
 *   graph.add_vertex(value)		    => descriptor
 *
 * Creates a new vertex in this subgraph and all its parents
 */
static
VALUE graph_add_vertex(VALUE self, VALUE vertex)
{
    BGLGraph&	graph = graph_wrapped(self);
    
    BGLGraph::vertex_descriptor descriptor = add_vertex(vertex, graph);
    return vertex_descriptor_to_rb(descriptor);
}

/*
 * call-seq:
 *  graph.remove_vertex(descriptor)		=> graph
 *
 * Removes +descriptor+ from the root graph and all subgraphs. There
 * is no way to remove a descriptor from only one subgraph
 */
static 
VALUE graph_remove_vertex(VALUE self, VALUE rb_descriptor)
{
    BGLGraph&	graph = graph_wrapped(self);
    
    BGLGraph::vertex_descriptor descriptor = rb_to_vertex_descriptor(rb_descriptor);
    remove_vertex(descriptor, graph);
    return self;
}

/*
 * call-seq:
 *  graph.insert(vertex)		    => graph
 *
 * Add +vertex+ in this graph.
 */
static
VALUE graph_insert(VALUE self, VALUE vertex)
{
    BGLGraph&	graph = graph_wrapped(self);
    graph_map&  vertex_graphs = vertex_descriptor_map(vertex);

    graph_map::iterator it;
    bool inserted;
    tie(it, inserted) = vertex_graphs.insert( make_pair(self, static_cast<void*>(0)) );
    if (inserted)
	it->second = add_vertex(vertex, graph);

    return self;
}

/*
 * call-seq:
 *   graph.remove(vertex)		    => graph
 * 
 * Remove +vertex+ from this graph.
 */
static
VALUE graph_remove(VALUE self, VALUE vertex)
{
    BGLGraph&	graph = graph_wrapped(self);
    graph_map&  vertex_graphs = vertex_descriptor_map(vertex);

    graph_map::iterator it = vertex_graphs.find(self);
    if (it == vertex_graphs.end())
	return self;

    clear_vertex(it->second, graph);
    remove_vertex(it->second, graph);
    vertex_graphs.erase(it);
    return self;
}

/*
 * call-seq:
 *  graph.include?(vertex)		    => true of false
 *
 * Returns true if +vertex+ is part of this graph.
 */
static
VALUE graph_include_p(VALUE self, VALUE vertex)
{
    bool includes;
    tie(tuples::ignore, includes) = rb_to_vertex(vertex, self);
    return includes ? Qtrue : Qfalse;
}


/*
 * call-seq:
 *    graph.add_edge(source_descriptor, target_descriptor, info)	    => graph
 *
 * Adds an edge between the nodes whose descriptors are +source_descriptor+ and
 * +target_descriptor+. +info+ is the object associated with the edge, which can
 * be retrieved later with #edge_data
 */
static
VALUE graph_add_edge(VALUE self, VALUE source, VALUE target, VALUE info)
{
    BGLGraph& graph = graph_wrapped(self);
    bool inserted = add_edge(rb_to_vertex_descriptor(source), rb_to_vertex_descriptor(target), info, graph).second;
    if (! inserted)
	rb_raise(rb_eArgError, "edge already exists");

    return self;
}

/*
 * call-seq:
 *    graph.edge_data(source_descriptor, target_descriptor)	    => info
 *
 * Returns the object associated with the edge between +source_descriptor+ and
 * +target_descriptor+. Raised ArgumentError if there is no such edge.
 */
static
VALUE graph_edge_data(VALUE self, VALUE rb_source, VALUE rb_target)
{
    BGLGraph& graph = graph_wrapped(self);
    vertex_descriptor source = rb_to_vertex_descriptor(rb_source), 
		      target = rb_to_vertex_descriptor(rb_target);

    bool b;
    edge_descriptor e;
    tie(e, b) = edge(source, target, graph);
    if (!b)
	rb_raise(rb_eArgError, "no such edge");

    return graph[e];
}

/*
 * call-seq:
 *    graph.remove_edge(source_descriptor, target_descriptor)	    => graph
 *
 * Removes the edge between +source_descriptor+ and +target_descriptor+. Does
 * nothing if the edge does not exist.
 */
static
VALUE graph_remove_edge(VALUE self, VALUE source, VALUE target)
{
    BGLGraph& graph = graph_wrapped(self);
    vertex_descriptor s = rb_to_vertex_descriptor(source), t = rb_to_vertex_descriptor(target);
    remove_edge(s, t, graph);
    return self;
}


// Make sure that the Vertex object +vertex+ is present in +self+, and returns
// its descriptor
static vertex_descriptor graph_ensure_inserted_vertex(VALUE self, VALUE vertex)
{
    vertex_descriptor v; bool exists;
    tie(v, exists) = rb_to_vertex(vertex, self);
    if (! exists)
    {
	graph_insert(self, vertex);
	tie(v, tuples::ignore) = rb_to_vertex(vertex, self);
    }

    return v;
}

/*
 * call-seq:
 *    graph.link(source, target, info)	    => graph
 *
 * Adds an edge from +source+ to +target+, with +info+ as property
 * Raises ArgumentError if the edge already exists.
 */
static
VALUE graph_link(VALUE self, VALUE source, VALUE target, VALUE info)
{
    BGLGraph& graph = graph_wrapped(self);

    vertex_descriptor 
	s = graph_ensure_inserted_vertex(self, source),
	t = graph_ensure_inserted_vertex(self, target);

    bool inserted = add_edge(s, t, info, graph).second;
    if (! inserted)
	rb_raise(rb_eArgError, "edge already exists");

    return self;
}

/*
 * call-seq:
 *    graph.unlink(source, target, info)	    => graph
 *
 * Removes the edge from +source+ to +target+. Does nothing if the 
 * edge does not exist.
 */
static
VALUE graph_unlink(VALUE self, VALUE source, VALUE target)
{
    BGLGraph& graph = graph_wrapped(self);

    vertex_descriptor s, t; bool exists;
    tie(s, exists) = rb_to_vertex(source, self);
    if (! exists) return self;
    tie(t, exists) = rb_to_vertex(target, self);
    if (! exists) return self;
    remove_edge(s, t, graph);
    return self;
}

/*
 * call-seq:
 *    graph.linked?(source, target)	    => true or false
 *
 * Checks if there is an edge from +source+ to +target+
 */
static
VALUE graph_linked_p(VALUE self, VALUE source, VALUE target)
{
    BGLGraph& graph = graph_wrapped(self);

    vertex_descriptor s, t; bool exists;
    tie(s, exists) = rb_to_vertex(source, self);
    if (! exists) return Qfalse;
    tie(t, exists) = rb_to_vertex(target, self);
    if (! exists) return Qfalse;
    return edge(s, t, graph).second ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *    graph.each_edge { |source, target, info| ... }     => graph
 *
 * Iterates on all edges in this graph. +source+ and +target+ are the
 * edge vertices, +info+ is the data associated with the edge. See #link.
 */
static
VALUE graph_each_edge(VALUE self)
{
    BGLGraph& graph = graph_wrapped(self);

    edge_iterator	  begin, end;
    tie(begin, end) = edges(graph);

    for (edge_iterator it = begin; it != end;)
    {
	VALUE from	= graph[source(*it, graph)];
	VALUE to	= graph[target(*it, graph)];
	VALUE data	= graph[*it];
	++it;

	rb_yield_values(3, from, to, data);
    }
    return self;
}




/**********************************************************************
 *  BGL::Vertex
 */

ID id_rb_graph_map;

static void vertex_free(graph_map* map) { delete map; }
static void vertex_mark(graph_map* map)
{
    for (graph_map::iterator it = map->begin(); it != map->end(); ++it)
	rb_gc_mark(it->first);
}

/* Returns the graph => descriptor map for +self+ */
static graph_map& vertex_descriptor_map(VALUE self)
{
    VALUE descriptors = rb_ivar_get(self, id_rb_graph_map);
    graph_map* map;
    if (NIL_P(descriptors))
    {
	map = new graph_map;
	VALUE rb_map = Data_Wrap_Struct(rb_cObject, vertex_mark, vertex_free, map);
	rb_ivar_set(self, id_rb_graph_map, rb_map);
    }
    else
	Data_Get_Struct(descriptors, graph_map, map);

    return *map;
}

/* Returns a range for all descriptors of +self+
 */
static
pair<graph_map::iterator, graph_map::iterator> vertex_descriptors(VALUE self)
{
    graph_map& descriptors = vertex_descriptor_map(self);
    return make_pair(descriptors.begin(), descriptors.end());
}

/* Return the vertex_descriptor of +self+ in +graph+. The boolean is true if
 * +self+ is in graph, and false otherwise.
 */
static
pair<vertex_descriptor, bool> rb_to_vertex(VALUE vertex, VALUE graph)
{
    graph_map& descriptors = vertex_descriptor_map(vertex);
    graph_map::iterator it = descriptors.find(graph);
    if(it == descriptors.end())
	return make_pair(static_cast<void*>(0), false);
    else
	return make_pair(it->second, true);
}

/*
 * call-seq:
 *	vertex.each_graph { |graph| ... }	    => self
 *
 * Iterates on all graphs this object is part of
 */
static VALUE vertex_each_graph(VALUE self)
{
    graph_map& graphs = vertex_descriptor_map(self);
    for (graph_map::iterator it = graphs.begin(); it != graphs.end();)
    {
	VALUE graph = it->first;
	// increment before calling rb_yield since the block
	// can call Graph#remove for instance
	++it;
	rb_yield(graph);
    }
    return self;
}

/*
 * call-seq:
 *  vertex.parent_object?(object[, graph])		=> true of false
 *
 * Checks if +object+ is a parent of +vertex+. If +graph+ is given,
 * check only in this graph. Otherwise, check in all graphs +vertex+
 * is part of.
 */
static VALUE vertex_parent_p(int argc, VALUE* argv, VALUE self)
{ 
    VALUE rb_parent, rb_graph = Qnil;
    rb_scan_args(argc, argv, "11", &rb_parent, &rb_graph);

    if (! NIL_P(rb_graph))
	return graph_linked_p(rb_graph, rb_parent, self);

    graph_map::iterator it, end;
    for (tie(it, end) = vertex_descriptors(self); it != end; ++it)
    {
	BGLGraph& graph     = graph_wrapped(it->first);
	vertex_descriptor child = it->second;
	vertex_descriptor parent; bool in_graph;
	tie(parent, in_graph) = rb_to_vertex(rb_parent, it->first);

	if (in_graph && edge(parent, child, graph).second)
	    return Qtrue;
    }
    return Qfalse;
}

/*
 * call-seq:
 *	vertex.child_vertex?(object[, graph])		=> true or false
 *
 * Checks if +object+ is a child of +vertex+ in +graph+. If +graph+ is given,
 * check only in this graph. Otherwise, check in all graphs +vertex+ is part
 * of.
 */
static VALUE vertex_child_p(int argc, VALUE* argv, VALUE self)
{ 
    swap(argv[0], self);
    return vertex_parent_p(argc, argv, self);
}

/*
 * call-seq:
 *	vertex.related_vertex?(object[, graph])		=> true or false
 *
 * Checks if +object+ is a child or a parent of +vertex+ in +graph+.  If
 * +graph+ is given, check only in this graph. Otherwise, check in all graphs
 * +vertex+ is part of.
 */
static VALUE vertex_related_p(int argc, VALUE* argv, VALUE self)
{
    if (vertex_parent_p(argc, argv, self) == Qtrue)
	return Qtrue;
    return vertex_child_p(argc, argv, self);
}

/** Iterates on all vertices in the range */
template <typename Range, typename F>
static bool for_each_value(Range range, BGLGraph& graph, F f)
{
    typedef typename Range::first_type Iterator;
    Iterator it, end;
    for (tie(it, end) = range; it != end; )
    {
	VALUE value = graph[*it];
	++it;

	if (!f(value))
	    return false;
    }
    return true;
}

/** Iterates on each adjacent vertex of +v+ in +graph+ which are not yet in +already_seen+ */
template <typename Graph, bool directed>
static bool for_each_adjacent_uniq(vertex_descriptor v, Graph const& graph, set<VALUE>& already_seen)
{
    typedef details::vertex_range<Graph, directed>	getter;
    typedef typename getter::iterator		        Iterator;

    Iterator it, end;
    for (tie(it, end) = details::vertex_range<Graph, directed>::get(v, graph); it != end; )
    {
	VALUE related_object = graph[*it];
	bool inserted;
	tie(tuples::ignore, inserted) = already_seen.insert(related_object);
	++it;

	if (inserted)
	    rb_yield_values(1, related_object);
    }
    return true;
}

/* Iterates on all graphs +vertex+ is part of, calling f(BGLGraph&, vertex_descriptor). If the calling
 * function returns false, stop iteration here */
template<typename F>
static bool for_each_graph(VALUE vertex, F f)
{
    graph_map::iterator graph, graph_end;
    for (tie(graph, graph_end) = vertex_descriptors(vertex); graph != graph_end;)
    {
	BGLGraph& g	    = graph_wrapped(graph->first);
	vertex_descriptor v = graph->second;
	++graph;

	if (!f(v, g))
	    return false;
    }
    return true;
}



template <bool directed>
static VALUE vertex_each_related(int argc, VALUE* argv, VALUE self)
{
    VALUE graph = Qnil;
    rb_scan_args(argc, argv, "01", &graph);

    if (NIL_P(graph))
    {
	set<VALUE> already_seen;
	for_each_graph(self, bind(for_each_adjacent_uniq<BGLGraph, directed>, _1, _2, ref(already_seen)));
    }
    else
    {
	vertex_descriptor v; bool exists;
	tie(v, exists) = rb_to_vertex(self, graph);
	if (! exists)
	    return self;

	BGLGraph& g = graph_wrapped(graph);
	for_each_value(details::vertex_range<BGLGraph, directed>::get(v, g), g, rb_yield);
    }
    return self;
}

/*
 * call-seq:
 *	vertex.each_parent_vertex([graph]) { |object| ... }	=> vertex
 *
 * Iterates on all parents of +vertex+. If +graph+ is given, only iterate on
 * the vertices that are parent in +graph+.
 */
static VALUE vertex_each_parent(int argc, VALUE* argv, VALUE self)
{ return vertex_each_related<false>(argc, argv, self); }

/*
 * call-seq:
 *	vertex.each_child_vertex([graph]) { |child| ... }		=> vertex
 *
 * Iterates on all children of +vertex+. If +graph+ is given, iterates only on
 * the vertices which are a child of +vertex+ in +graph+
 */
static VALUE vertex_each_child(int argc, VALUE* argv, VALUE self)
{ return vertex_each_related<true>(argc, argv, self); }

/*
 * call-seq:
 *	vertex[child, graph]				    => info
 *
 * Get the data associated with the vertex => +child+ edge in +graph+.
 * Raises ArgumentError if there is no such edge.
 */
static VALUE vertex_get_info(VALUE self, VALUE child, VALUE rb_graph)
{
    vertex_descriptor source, target; bool exists;

    tie(source, exists) = rb_to_vertex(self, rb_graph);
    if (! exists)
	rb_raise(rb_eArgError, "self is not in graph");
    tie(target, exists) = rb_to_vertex(child, rb_graph);
    if (! exists)
	rb_raise(rb_eArgError, "child is not in graph");

    BGLGraph& graph = graph_wrapped(rb_graph);
    edge_descriptor e;
    tie(e, exists) = edge(source, target, graph);
    if (! exists)
	rb_raise(rb_eArgError, "no such edge in graph");

    return graph[e];
}

// Returns true if +v+ has either no child (if +directed+ is true) or no parents (if +directed+ is false)
template<typename Graph, bool directed>
static bool vertex_has_adjacent_i(vertex_descriptor v, Graph const& g)
{
    typedef typename details::vertex_range<Graph, directed> getter;
    typename getter::iterator begin, end;
    tie(begin, end) = getter::get(v, g);
    return begin == end;
}

template<bool directed>
static VALUE vertex_has_adjacent(int argc, VALUE* argv, VALUE self)
{
    VALUE graph = Qnil;
    rb_scan_args(argc, argv, "01", &graph);

    bool result;
    if (NIL_P(graph))
	result = for_each_graph(self, vertex_has_adjacent_i<BGLGraph, directed>);
    else
    {
	vertex_descriptor v; bool exists;
	tie(v, exists) = rb_to_vertex(self, graph);
	if (! exists)
	    return Qtrue;

	BGLGraph& g = graph_wrapped(graph);
	result = vertex_has_adjacent_i<BGLGraph, directed>(v, g);
    }
    return result ? Qtrue : Qfalse;
}
/*
 * call-seq:
 *   vertex.root?([graph])
 *
 * Checks if +vertex+ is a root node in +graph+ (it has no parents), or if graph is not given, in all graphs 
 */
static VALUE vertex_root_p(int argc, VALUE* argv, VALUE self)
{ return vertex_has_adjacent<false>(argc, argv, self); }


/*
 * call-seq:
 *   vertex.leaf?([graph])
 *
 * Checks if +vertex+ is a root node in +graph+ (it has no children), or if graph is not given, in all graphs 
 */
static VALUE vertex_leaf_p(int argc, VALUE* argv, VALUE self)
{ return vertex_has_adjacent<true>(argc, argv, self); }









/* If +key+ is found in +assoc+, returns its value. Otherwise, initializes 
 * +key+ to +default_value+ in +assoc+ and returns it
 */
template<typename Key, typename Value>
Value& get(map<Key, Value>& assoc, Key const& key, Value const& default_value)
{
    typename map<Key, Value>::iterator it = assoc.find(key);
    if (it != assoc.end())
	return it->second;

    tie(it, tuples::ignore) = assoc.insert( make_pair(key, default_value) );
    return it->second;
}

/* If +key+ is found in +assoc+, returns its value. Otherwise, initializes 
 * +key+ to +default_value+ in +assoc+ and returns it
 */
template<typename Key, typename Value>
Value const& get(map<Key, Value> const& assoc, Key const& key, Value const& default_value)
{
    typename map<Key, Value>::const_iterator it = assoc.find(key);
    if (it != assoc.end())
	return it->second;

    return default_value;
}

/* ColorMap is a map with default value */
class ColorMap : private map<vertex_descriptor, default_color_type>
{
    template<typename Key, typename Value>
    friend Value& get(map<Key, Value>&, Key const&, Value const&);

    default_color_type const default_value;

    typedef map<vertex_descriptor, default_color_type> Super;

public:

    typedef Super::key_type	key_type;
    typedef Super::value_type	value_type;

    Super::clear;

    ColorMap()
	: default_value(color_traits<default_color_type>::white()) {}

    default_color_type& operator[](vertex_descriptor key)
    { 
	default_color_type& c = get(*this, key, default_value); 
	return c;
    }

};

typedef list<vertex_descriptor> vertex_list;

struct components_visitor : public default_dfs_visitor
{
public:
    vertex_descriptor root;
    set<VALUE>&  component;
    vertex_list& reverse;
    components_visitor( vertex_descriptor root, set<VALUE>& component, vertex_list& reverse )
	: root(root), component(component), reverse(reverse) { }

    template<typename G>
    void discover_vertex(vertex_descriptor u, G const& g)
    {
	component.insert(g[u]);

	typename G::in_edge_iterator it, end;
	tie(it, end) = in_edges(u, g);
	// never add root automatically, it has to be handled by the algorithm itself
	if (u != root && ++it != end)
	    reverse.push_back(u);
    }
};

template<typename Graph>
static bool connected_component(bool directed, set<VALUE>& component, vertex_descriptor v, Graph const& graph, ColorMap& colors)
{
    vertex_list roots;
    vertex_list reverse_roots;

    associative_property_map<ColorMap> color_map(colors);
    boost::reverse_graph<Graph, const Graph&> reverse_graph(graph);

    roots.push_back(v);
    reverse_roots.push_back(v);
    while(true)
    {
	if (roots.empty()) break;
	for (list<vertex_descriptor>::const_iterator it = roots.begin(); it != roots.end(); ++it)
	    depth_first_visit(graph, *it, components_visitor(*it, component, reverse_roots), color_map);

	roots.clear();

	if (directed || reverse_roots.empty()) break;
	for (list<vertex_descriptor>::const_iterator it = reverse_roots.begin(); it != reverse_roots.end(); ++it)
	    depth_first_visit(reverse_graph, *it, components_visitor(*it, component, roots), color_map);

	reverse_roots.clear();
    }
    return true;
}

static VALUE set_to_rb(set<VALUE>& source)
{
    VALUE result = rb_funcall(utilrbValueSet, id_new, 0);
    set<VALUE>* result_set;
    Data_Get_Struct(result, set<VALUE>, result_set);

    result_set->swap(source);
    return result;
}

template<typename Graph, typename Iterator>
static VALUE graph_components_i(bool directed, VALUE result, Graph const& g, Iterator it, Iterator end)
{
    ColorMap colors;

    for (; it != end; ++it)
    {
	if (0 == *it) // elements not in +g+  are handled by graph_components_root_descriptor
	    continue;
	if (colors[*it] != color_traits<default_color_type>::white())
	    continue;

	set<VALUE> component;
	connected_component(directed, component, *it, g, colors);
	rb_ary_push(result, set_to_rb(component));
    }

    return result;
}

static vertex_descriptor graph_components_root_descriptor(VALUE result, VALUE v, VALUE g)
{
    vertex_descriptor d;
    bool exists;
    tie(d, exists) = rb_to_vertex(v, g);
    if (! exists)
    {
	set<VALUE> component;
	component.insert(v);
	rb_ary_push(result, set_to_rb(component));
	return NULL;
    }
    return d;
}
template<typename Graph>
static VALUE graph_do_components(bool directed, int argc, VALUE* argv, Graph const& g, VALUE self)
{
    VALUE result = rb_ary_new();
    if (argc == 0)
    {
	BGLGraph::vertex_iterator it, end;
	tie(it, end) = vertices(g);
	return graph_components_i(directed, result, g, 
		make_filter_iterator(
		    bind(
			vertex_has_adjacent_i<Graph, false>, 
			_1, ref(g)
		    ), it, end
		),
		make_filter_iterator(
		    bind(
			vertex_has_adjacent_i<Graph, false>, 
			_1, ref(g)
		    ), end, end
		)
	    );
    }
    else
    {
	return graph_components_i(directed, result, g, 
		make_transform_iterator(argv, 
		    bind(graph_components_root_descriptor, result, _1, self)
		),
		make_transform_iterator(argv + argc, 
		    bind(graph_components_root_descriptor, result, _1, self)
		));
    }
}
/*
 * call-seq:
 *   graph.components([v1, v2, ...])			    => components
 *
 * Returns an array of vertex sets. Each set is a connected component of +graph+. If
 * a list of vertices is provided, returns only the components the vertices are part of.
 * The graph is treated as if it were not directed.
 */
static VALUE graph_components(int argc, VALUE* argv, VALUE self)
{ return graph_do_components(false, argc, argv, graph_wrapped(self), self); }
/* call-seq:
 *   graph.directed_components([v1, v2, ...])		   => components
 *
 * Like Graph#components, but do not go backwards on edges
 */
static VALUE graph_directed_components(int argc, VALUE* argv, VALUE self)
{ return graph_do_components(true, argc, argv, graph_wrapped(self), self); }
/* call-seq:
 *   graph.directed_components([v1, v2, ...])		   => components
 *
 * Like Graph#directed_components, but on the reverse graph of +graph+ (where edges has
 * been swapped)
 */
static VALUE graph_reverse_directed_components(int argc, VALUE* argv, VALUE self)
{ return graph_do_components(true, argc, argv, make_reverse_graph(graph_wrapped(self)), self); }

/**********************************************************************
 *  Extension initialization
 */

static VALUE bglModule;
static VALUE bglGraph;
static VALUE bglVertex;

/*
 * Document-module: BGL
 *
 * The BGL module defines a Graph class and a Vertex module. The Graph class can
 * be used to manipulate graphs where vertices are referenced by a graph descriptor
 * (Graph#add_edge, Graph#add_vertex, ...). However, the preferred way to us BGL is
 * to mix Vertex in the vertex objects and use the associated methods:
 * 
 *   class MyNode
 *     include BGL::Graph
 *   end
 *   graph = Graph.new
 *   v1, v2 = MyNode.new, MyNode.new
 *   graph.link(v1, v2, [])
 *   ...
 *   v1.each_child_object { ... }
 */

/*
 * Document-class: BGL::Graph
 *
 * A directed graph between Ruby objects. See BGL documentation.
 */

/*
 * Document-module: BGL::Vertex
 *
 * A module to be mixed in objects used as vertices in Graph. It
 * allows to use the same object in more than one graph.
 */

extern "C" void Init_bgl()
{
    id_rb_graph_map = rb_intern("@__bgl_graphs__");
    id_new = rb_intern("new");
    utilrbValueSet = rb_define_class("ValueSet", rb_cObject);

    bglModule = rb_define_module("BGL");
    bglGraph  = rb_define_class_under(bglModule, "Graph", rb_cObject);
    rb_define_alloc_func(bglGraph, graph_alloc);

    // Functions which manipulates descriptors
    rb_define_method(bglGraph, "add_vertex",	RUBY_METHOD_FUNC(graph_add_vertex), 1);
    rb_define_method(bglGraph, "remove_vertex", RUBY_METHOD_FUNC(graph_remove_vertex), 1);
    rb_define_method(bglGraph, "vertex_data",	RUBY_METHOD_FUNC(graph_vertex_data), 1);
    rb_define_method(bglGraph, "add_edge",	RUBY_METHOD_FUNC(graph_add_edge), 3);
    rb_define_method(bglGraph, "remove_edge",	RUBY_METHOD_FUNC(graph_remove_edge), 2);
    rb_define_method(bglGraph, "edge_data",	RUBY_METHOD_FUNC(graph_edge_data), 2);

    // Functions to manipulate BGL::Vertex objects in Graphs
    rb_define_method(bglGraph, "insert",    RUBY_METHOD_FUNC(graph_insert), 1);
    rb_define_method(bglGraph, "remove",    RUBY_METHOD_FUNC(graph_remove), 1);
    rb_define_method(bglGraph, "include?",  RUBY_METHOD_FUNC(graph_include_p), 1);
    rb_define_method(bglGraph, "link",	    RUBY_METHOD_FUNC(graph_link), 3);
    rb_define_method(bglGraph, "unlink",    RUBY_METHOD_FUNC(graph_unlink), 2);
    rb_define_method(bglGraph, "linked?",   RUBY_METHOD_FUNC(graph_linked_p), 2);
    rb_define_method(bglGraph, "components",   RUBY_METHOD_FUNC(graph_components), -1);
    rb_define_method(bglGraph, "directed_components",   RUBY_METHOD_FUNC(graph_directed_components), -1);
    rb_define_method(bglGraph, "reverse_directed_components",   RUBY_METHOD_FUNC(graph_reverse_directed_components), -1);

    rb_define_method(bglGraph, "each_vertex",	RUBY_METHOD_FUNC(graph_each_vertex), 0);
    rb_define_method(bglGraph, "each_edge",	RUBY_METHOD_FUNC(graph_each_edge), 0);

    bglVertex = rb_define_module_under(bglModule, "Vertex");
    rb_define_method(bglVertex, "related_vertex?",	RUBY_METHOD_FUNC(vertex_related_p), -1);
    rb_define_method(bglVertex, "parent_vertex?",	RUBY_METHOD_FUNC(vertex_parent_p), -1);
    rb_define_method(bglVertex, "child_vertex?",	RUBY_METHOD_FUNC(vertex_child_p), -1);
    rb_define_method(bglVertex, "each_child_vertex",	RUBY_METHOD_FUNC(vertex_each_child), -1);
    rb_define_method(bglVertex, "each_parent_vertex",	RUBY_METHOD_FUNC(vertex_each_parent), -1);
    rb_define_method(bglVertex, "each_graph",		RUBY_METHOD_FUNC(vertex_each_graph), 0);
    rb_define_method(bglVertex, "root?",		RUBY_METHOD_FUNC(vertex_root_p), -1);
    rb_define_method(bglVertex, "leaf?",		RUBY_METHOD_FUNC(vertex_leaf_p), -1);
    rb_define_method(bglVertex, "[]",			RUBY_METHOD_FUNC(vertex_get_info), 2);
    // rb_define_method(bglVertex, "component",		RUBY_METHOD_FUNC(vertex_component), -1);
}

