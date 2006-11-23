#include <ruby.h>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/depth_first_search.hpp>
#include <boost/graph/breadth_first_search.hpp>
#include <boost/graph/reverse_graph.hpp>
#include <boost/iterator/transform_iterator.hpp>
#include <boost/iterator/filter_iterator.hpp>
#include <boost/graph/connected_components.hpp>
#include <boost/bind.hpp>
#include <utilmm/undirected_graph.hh>
#include <queue>
#include <functional>

static VALUE utilrbValueSet;
static ID id_new;

using namespace boost;
using namespace std;

template<typename T>
struct Queue : std::queue<T>
{
    T& top() { return this->front(); }
    T const& top() const { return this->front(); }
};

/**********************************************************************
 *  Definition of base C++ types
 */

typedef adjacency_list< boost::setS, boost::setS
		      , boost::bidirectionalS, VALUE, VALUE>	BGLGraph;

typedef BGLGraph::vertex_iterator	vertex_iterator;
typedef BGLGraph::vertex_descriptor	vertex_descriptor;
typedef BGLGraph::edge_iterator		edge_iterator;
typedef BGLGraph::edge_descriptor	edge_descriptor;

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

struct vertex_recorder : public default_dfs_visitor
{
public:
    set<VALUE>&  component;
    vertex_recorder( set<VALUE>& component )
	: component(component) { }

    template<typename G>
    void discover_vertex(vertex_descriptor u, G const& g)
    { component.insert(g[u]); }
};



/** Converts a std::set<VALUE> into a ValueSet object */
static VALUE set_to_rb(set<VALUE>& source)
{
    VALUE result = rb_funcall(utilrbValueSet, id_new, 0);
    set<VALUE>* result_set;
    Data_Get_Struct(result, set<VALUE>, result_set);

    result_set->swap(source);
    return result;
}

/* Adds in +result+ all components generated by the items in [it, end). We 
 * assume that there is no component which includes more than one item in
 * [it, end) */
template<typename Graph, typename Iterator>
static VALUE graph_components_i(VALUE result, Graph const& g, Iterator it, Iterator end)
{
    ColorMap   colors;
    set<VALUE> component;

    for (; it != end; ++it)
    {
	if (0 == *it) // elements not in +g+  are handled by graph_components_root_descriptor
	    continue;
	if (colors[*it] != color_traits<default_color_type>::white())
	    continue;

	depth_first_visit(g, *it, vertex_recorder(component), make_assoc_property_map(colors));
	rb_ary_push(result, set_to_rb(component));
	component.clear();
    }

    return result;
}

/** If +v+ is found in +g+, returns the corresponding vertex_descriptor. Otherwise,
 * add a singleton component to +result+ and return NULL.
 */
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
static VALUE graph_do_components(int argc, VALUE* argv, Graph const& g, VALUE self)
{
    VALUE result = rb_ary_new();
    if (argc == 0)
    {
	BGLGraph::vertex_iterator it, end;
	tie(it, end) = vertices(g);
	// call graph_components_i with all root vertices
	// in +graph+
	return graph_components_i(result, g, 
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
	// call graph_components_i with all vertices given in as argument
	return graph_components_i(result, g, 
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
{ 
    // Compute the connected components
    BGLGraph const& g = graph_wrapped(self);
    utilmm::undirected_graph<BGLGraph> undirected(g);

    typedef std::map<vertex_descriptor, int> ComponentMap;
    ComponentMap component_map;
    ColorMap	 color_map;
    int count = connected_components(undirected, 
	    make_assoc_property_map(component_map), 
	    boost::color_map( make_assoc_property_map(color_map) ));

    VALUE ret = rb_ary_new2(count);
    std::vector<bool>  enabled_components;
    std::vector<VALUE> components(count);
    if (0 == argc)
	enabled_components.resize(count, true);
    else
    {
	enabled_components.resize(count, false);
	for (int i = 0; i < argc; ++i)
	{
	    vertex_descriptor v; bool in_graph;
	    tie(v, in_graph) = rb_to_vertex(argv[i], self);
	    if (! in_graph)
		rb_ary_push(ret, rb_ary_new3(1, argv[i]));
	    else
	    {
		int v_c = component_map[v];
		enabled_components[v_c] = true;
	    }
	}
    }

    // Add empty array for all enabled components
    for (int i = 0; i < count; ++i)
    {
	if (! enabled_components[i]) continue;
	VALUE ary = components[i] = rb_ary_new();
	rb_ary_store(ret, i, ary);
    }

    // Add the vertices to their corresponding Ruby component
    for (ComponentMap::const_iterator it = component_map.begin(); it != component_map.end(); ++it)
    {
	int c = it->second;
	if (! enabled_components[c])
	    continue;

	rb_ary_push(components[c], g[it->first]);
    }

    // Remove all unused component slots (disabled components)
    rb_funcall(ret, rb_intern("compact!"), 0);
    return ret;

    // return graph_do_components(false, argc, argv, graph_wrapped(self), self); 
}
/* call-seq:
 *   graph.directed_components([v1, v2, ...])		   => components
 *
 * Like Graph#components, but do not go backwards on edges
 */
static VALUE graph_directed_components(int argc, VALUE* argv, VALUE self)
{ return graph_do_components(argc, argv, graph_wrapped(self), self); }
/* call-seq:
 *   graph.directed_components([v1, v2, ...])		   => components
 *
 * Like Graph#directed_components, but on the reverse graph of +graph+ (where edges has
 * been swapped)
 */
static VALUE graph_reverse_directed_components(int argc, VALUE* argv, VALUE self)
{ return graph_do_components(argc, argv, make_reverse_graph(graph_wrapped(self)), self); }



static const int VISIT_TREE_EDGES = 1;
static const int VISIT_BACK_EDGES = 2;
static const int VISIT_FORWARD_OR_CROSS_EDGES = 4;
static const int VISIT_NON_TREE_EDGES = 6;
static const int VISIT_ALL_EDGES = 7;

struct ruby_dfs_visitor : public default_dfs_visitor
{

    int m_mode;
    ruby_dfs_visitor(int mode)
	: m_mode(mode) { } 

    template<typename G>
    void tree_edge(edge_descriptor e, G const& graph)
    { yield_edge(e, graph, VISIT_TREE_EDGES); }
    template<typename G>
    void back_edge(edge_descriptor e, G const& graph)
    { yield_edge(e, graph, VISIT_BACK_EDGES); }
    template<typename G>
    void forward_or_cross_edge(edge_descriptor e, G const& graph)
    { yield_edge(e, graph, VISIT_FORWARD_OR_CROSS_EDGES); }

    template<typename G>
    void yield_edge(edge_descriptor e, G const& graph, int what)
    {
	if (!(what & m_mode))
	    return;

	VALUE source = graph[boost::source(e, graph)];
	VALUE target = graph[boost::target(e, graph)];
	VALUE info = graph[e];
	rb_yield_values(4, source, target, info, INT2FIX(what));
    }
};

template<typename G>
static bool search_terminator(vertex_descriptor u, G const& g)
{ 
    VALUE thread = rb_thread_current();
    bool result = RTEST(rb_thread_local_aref(thread, rb_intern("@prune")));
    if (result)
	rb_thread_local_aset(thread, rb_intern("@prune"), Qfalse);
    return result;
}

static VALUE graph_prune(VALUE self)
{
    VALUE thread = rb_thread_current();
    rb_thread_local_aset(thread, rb_intern("@prune"), Qtrue);
    return Qtrue;
}

template<typename Graph>
static VALUE graph_each_dfs(VALUE self, Graph& graph, VALUE root, VALUE mode)
{
    vertex_descriptor v; bool exists;
    tie(v, exists) = rb_to_vertex(root, self);
    if (! exists)
	return self;

    map<vertex_descriptor, default_color_type> colors;
    depth_first_visit(graph, v, ruby_dfs_visitor(FIX2INT(mode)), 
	    make_assoc_property_map(colors), &search_terminator<Graph>);
    return self;
}

static VALUE graph_each_dfs_direct(VALUE self, VALUE root, VALUE mode)
{
    BGLGraph& graph = graph_wrapped(self);
    return graph_each_dfs(self, graph, root, mode);
}
static VALUE graph_each_dfs_reverse(VALUE self, VALUE root, VALUE mode)
{
    BGLGraph& graph = graph_wrapped(self);
    boost::reverse_graph<BGLGraph, const BGLGraph&> reverse_graph(graph);
    return graph_each_dfs(self, reverse_graph, root, mode);
}




struct ruby_bfs_visitor : public default_bfs_visitor
{
    int m_mode;
    ruby_bfs_visitor(int mode)
	: m_mode(mode) { } 

    template<typename E, typename G>
    void tree_edge(E e, G const& graph)
    { yield_edge(e, graph, VISIT_TREE_EDGES); }
    template<typename E, typename G>
    void non_tree_edge(E e, G const& graph)
    { yield_edge(e, graph, VISIT_NON_TREE_EDGES); }
    template<typename E, typename G>
    void yield_edge(E e, G const& graph, int what)
    {
	if (!(what & m_mode))
	    return;

	VALUE source_vertex = graph[source(e, graph)];
	VALUE target_vertex = graph[target(e, graph)];
	VALUE info = graph[e];
	rb_yield_values(4, source_vertex, target_vertex, info, INT2FIX(what));
    }
};

template<typename Graph>
static VALUE graph_each_bfs(VALUE self, Graph& graph, VALUE root, VALUE mode)
{
    int intmode = FIX2INT(mode);
    if ((intmode & VISIT_NON_TREE_EDGES) && ((intmode & VISIT_NON_TREE_EDGES) != VISIT_NON_TREE_EDGES))
	rb_raise(rb_eArgError, "cannot use FORWARD_OR_CROSS and BACK");

    vertex_descriptor v; bool exists;
    tie(v, exists) = rb_to_vertex(root, self);
    if (! exists)
	return self;

    map<vertex_descriptor, default_color_type> colors;
    Queue<vertex_descriptor> queue;
    breadth_first_search(graph, v, queue, ruby_bfs_visitor(intmode), 
	    make_assoc_property_map(colors));
    return self;
}

static VALUE graph_each_bfs_direct(VALUE self, VALUE root, VALUE mode)
{
    BGLGraph& graph = graph_wrapped(self);
    return graph_each_bfs(self, graph, root, mode);
}

static VALUE graph_each_bfs_reverse(VALUE self, VALUE root, VALUE mode)
{
    BGLGraph& graph = graph_wrapped(self);
    boost::reverse_graph<BGLGraph, const BGLGraph&> reverse_graph(graph);
    return graph_each_bfs(self, reverse_graph, root, mode);
}
static VALUE graph_each_bfs_undirected(VALUE self, VALUE root, VALUE mode)
{
    BGLGraph& graph = graph_wrapped(self);
    utilmm::undirected_graph<BGLGraph, const BGLGraph&> undirected_graph(graph);
    return graph_each_bfs(self, undirected_graph, root, mode);
}

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
    rb_define_const(bglGraph , "TREE"             , INT2FIX(VISIT_TREE_EDGES));
    rb_define_const(bglGraph , "FORWARD_OR_CROSS" , INT2FIX(VISIT_FORWARD_OR_CROSS_EDGES));
    rb_define_const(bglGraph , "BACK"             , INT2FIX(VISIT_BACK_EDGES));
    rb_define_const(bglGraph , "NON_TREE"         , INT2FIX(VISIT_NON_TREE_EDGES));
    rb_define_const(bglGraph , "ALL"              , INT2FIX(VISIT_ALL_EDGES));

    rb_define_method(bglGraph, "each_vertex",	RUBY_METHOD_FUNC(graph_each_vertex), 0);
    rb_define_method(bglGraph, "each_edge",	RUBY_METHOD_FUNC(graph_each_edge), 0);
    rb_define_method(bglGraph, "each_dfs",	RUBY_METHOD_FUNC(graph_each_dfs_direct), 2);
    rb_define_method(bglGraph, "reverse_each_dfs",	RUBY_METHOD_FUNC(graph_each_dfs_reverse), 2);
    rb_define_method(bglGraph, "each_bfs",	RUBY_METHOD_FUNC(graph_each_bfs_direct), 2);
    rb_define_method(bglGraph, "reverse_each_bfs",	RUBY_METHOD_FUNC(graph_each_bfs_reverse), 2);
    rb_define_method(bglGraph, "undirected_each_bfs",	RUBY_METHOD_FUNC(graph_each_bfs_undirected), 2);
    rb_define_method(bglGraph, "prune",		RUBY_METHOD_FUNC(graph_prune), 0);

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

