#include <ruby.h>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/subgraph.hpp>
#include <boost/static_assert.hpp>
#include <boost/type_traits/is_same.hpp>
#include <boost/bind.hpp>

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
typedef std::map<VALUE, vertex_descriptor>	graph_map;

static graph_map& vertex_descriptor_map(VALUE self);
static std::pair<vertex_descriptor, bool> rb_to_vertex(VALUE vertex, VALUE graph);

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

    for (vertex_iterator it = begin; it != end; ++it)
	rb_yield_values(1, graph[*it]);
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

    for (edge_iterator it = begin; it != end; ++it)
    {
	VALUE from	= graph[source(*it, graph)];
	VALUE to	= graph[target(*it, graph)];
	VALUE data	= graph[*it];

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
std::pair<graph_map::iterator, graph_map::iterator> vertex_descriptors(VALUE self)
{
    graph_map& descriptors = vertex_descriptor_map(self);
    return make_pair(descriptors.begin(), descriptors.end());
}

/* Return the vertex_descriptor of +self+ in +graph+. The boolean is true if
 * +self+ is in graph, and false otherwise.
 */
static
std::pair<vertex_descriptor, bool> rb_to_vertex(VALUE vertex, VALUE graph)
{
    graph_map& descriptors = vertex_descriptor_map(vertex);
    graph_map::iterator it = descriptors.find(graph);
    return make_pair(it->second, it != descriptors.end());
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
    for (graph_map::iterator it = graphs.begin(); it != graphs.end(); ++it)
	rb_yield_values(1, it->first);
    return self;
}

/*
 * call-seq:
 *  vertex.parent_object?(object)		=> true of false
 *
 * Checks if +object+ is a parent of +vertex+
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
 *	vertex.child_vertex?(object)		=> true or false
 *
 * Checks if +object+ is a child of +vertex+ in +graph+. If +graph+ 
 * is nil, check in all graphs
 */
static VALUE vertex_child_p(int argc, VALUE* argv, VALUE self)
{ 
    std::swap(argv[0], self);
    return vertex_parent_p(argc, argv, self);
}

/*
 * call-seq:
 *	vertex.related_vertex?(object)		=> true or false
 *
 * Checks if +object+ is a child or a parent of +vertex+ in +graph+.
 * If +graph+ is nil, check in all graphs
 */
static VALUE vertex_related_p(int argc, VALUE* argv, VALUE self)
{
    if (vertex_parent_p(argc, argv, self) == Qtrue)
	return Qtrue;
    return vertex_child_p(argc, argv, self);
}

template<typename iterator, typename range_t>
static void vertex_each_related(BGLGraph& graph, range_t range, set<VALUE>& already_seen)
{
    iterator it, end;
    for (tie(it, end) = range; it != end; ++it)
    {
	VALUE related_object = graph[*it];
	bool inserted;
	tie(tuples::ignore, inserted) = already_seen.insert(related_object);
	if (inserted)
	    rb_yield_values(1, related_object);
    }
}
template<typename iterator, typename range_getter>
static void vertex_each_related(VALUE vertex, range_getter f, std::set<VALUE>& already_seen)
{
    graph_map::iterator graph, graph_end;
    for (tie(graph, graph_end) = vertex_descriptors(vertex); graph != graph_end; ++graph)
    {
	BGLGraph& g	    = graph_wrapped(graph->first);
	vertex_descriptor v = graph->second;
	vertex_each_related<iterator>(g, f(v, g), already_seen);
    }
}



static std::pair<BGLGraph::inv_adjacency_iterator, BGLGraph::inv_adjacency_iterator>
vertex_parent_range(vertex_descriptor v, BGLGraph& graph) { return inv_adjacent_vertices(v, graph); }

/*
 * call-seq:
 *	vertex.each_parent_vertex([graph]) { |object| ... }	=> vertex
 *
 * Iterates on all parents of +vertex+. If +graph+ is given, only iterate on
 * the vertices that are parent in +graph+.
 */
static VALUE vertex_each_parent(int argc, VALUE* argv, VALUE self)
{ 
    VALUE graph = Qnil;
    rb_scan_args(argc, argv, "01", &graph);
    set<VALUE> already_seen;

    if (NIL_P(graph))
	vertex_each_related<BGLGraph::inv_adjacency_iterator>(self, &vertex_parent_range, already_seen);
    else
    {
	vertex_descriptor target; bool exists;
	tie(target, exists) = rb_to_vertex(self, graph);
	if (! exists)
	    return self;

	BGLGraph& g = graph_wrapped(graph);
	vertex_each_related<BGLGraph::inv_adjacency_iterator>(g, inv_adjacent_vertices(target, g), already_seen);
    }
    return self;
}



static std::pair<BGLGraph::adjacency_iterator, BGLGraph::adjacency_iterator>
vertex_child_range(vertex_descriptor v, BGLGraph& graph) { return adjacent_vertices(v, graph); }

/*
 * call-seq:
 *	vertex.each_child_vertex([graph]) { |child| ... }		=> vertex
 *
 * Iterates on all children of +vertex+. If +graph+ is given, iterates only on
 * the vertices which are a child of +vertex+ in +graph+
 */
static VALUE vertex_each_child(int argc, VALUE* argv, VALUE self)
{
    VALUE graph = Qnil;
    rb_scan_args(argc, argv, "01", &graph);
    set<VALUE> already_seen;

    if (NIL_P(graph))
	vertex_each_related<BGLGraph::adjacency_iterator>(self, &vertex_child_range, already_seen);
    else
    {
	vertex_descriptor source; bool exists;
	tie(source, exists) = rb_to_vertex(self, graph);
	if (! exists)
	    return self;

	BGLGraph& g = graph_wrapped(graph);
	vertex_each_related<BGLGraph::adjacency_iterator>(g, adjacent_vertices(source, g), already_seen);

    }
    return self;
}

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

    // Functions to manipulate BGL::Vertex objects
    rb_define_method(bglGraph, "insert",    RUBY_METHOD_FUNC(graph_insert), 1);
    rb_define_method(bglGraph, "remove",    RUBY_METHOD_FUNC(graph_remove), 1);
    rb_define_method(bglGraph, "include?",  RUBY_METHOD_FUNC(graph_include_p), 1);
    rb_define_method(bglGraph, "link",	    RUBY_METHOD_FUNC(graph_link), 3);
    rb_define_method(bglGraph, "unlink",    RUBY_METHOD_FUNC(graph_unlink), 2);
    rb_define_method(bglGraph, "linked?",   RUBY_METHOD_FUNC(graph_linked_p), 2);

    rb_define_method(bglGraph, "each_vertex",	RUBY_METHOD_FUNC(graph_each_vertex), 0);
    rb_define_method(bglGraph, "each_edge",	RUBY_METHOD_FUNC(graph_each_edge), 0);

    bglVertex = rb_define_module_under(bglModule, "Vertex");
    rb_define_method(bglVertex, "related_vertex?",	RUBY_METHOD_FUNC(vertex_related_p), -1);
    rb_define_method(bglVertex, "parent_vertex?",	RUBY_METHOD_FUNC(vertex_parent_p), -1);
    rb_define_method(bglVertex, "child_vertex?",	RUBY_METHOD_FUNC(vertex_child_p), -1);
    rb_define_method(bglVertex, "each_child_vertex",	RUBY_METHOD_FUNC(vertex_each_child), -1);
    rb_define_method(bglVertex, "each_parent_vertex",	RUBY_METHOD_FUNC(vertex_each_parent), -1);
    rb_define_method(bglVertex, "each_graph",		RUBY_METHOD_FUNC(vertex_each_graph), 0);
    rb_define_method(bglVertex, "[]",		RUBY_METHOD_FUNC(vertex_get_info), 2);
}

