#include "graph.hh"
#include <boost/bind.hpp>
#include <functional>

static ID id_rb_graph_map;

typedef RubyGraph::vertex_iterator	vertex_iterator;
typedef RubyGraph::vertex_descriptor	vertex_descriptor;
typedef RubyGraph::edge_iterator	edge_iterator;
typedef RubyGraph::edge_descriptor	edge_descriptor;

using namespace boost;
using namespace std;

VALUE bglModule;
VALUE bglGraph;
VALUE bglReverseGraph;
VALUE bglUndirectedGraph;
VALUE bglVertex;

/**********************************************************************
 *  BGL::Graph
 */

template <typename descriptor> static 
void graph_mark_object_property(RubyGraph& graph, descriptor object)
{ 
}

static 
void graph_mark(RubyGraph* graph) { 
    { vertex_iterator it, end;
	for (tie(it, end) = vertices(*graph); it != end; ++it)
	{
	    VALUE value = (*graph)[*it];
	    if (! NIL_P(value))
		rb_gc_mark(value); 
	}
    }

    { edge_iterator it, end;
	for (tie(it, end) = edges(*graph); it != end; ++it)
	{
	    VALUE value = (*graph)[*it].info;
	    if (! NIL_P(value))
		rb_gc_mark(value); 
	}
    }
}

static void graph_free(RubyGraph* graph) { delete graph; }
static VALUE graph_alloc(VALUE klass)
{
    RubyGraph* graph = new RubyGraph;
    VALUE rb_graph = Data_Wrap_Struct(klass, graph_mark, graph_free, graph);
    return rb_graph;
}

/* @overload vertices
 *
 * @return [Array<Object>] all vertices contained in +graph+
 */
static
VALUE graph_vertices(VALUE self)
{
    RubyGraph& graph = graph_wrapped(self);

    vertex_iterator begin, end;
    tie(begin, end) = vertices(graph);

    VALUE result = rb_ary_new();
    for (vertex_iterator it = begin; it != end; ++it)
        rb_ary_push(result, graph[*it]);
    return result;
}

/* @overload empty?
 *
 * @return [Boolean] whether this graph contains vertices or not
 */
static
VALUE graph_empty_p(VALUE self)
{
    RubyGraph& graph = graph_wrapped(self);

    vertex_iterator begin, end;
    tie(begin, end) = vertices(graph);
    return (begin == end) ? Qtrue : Qfalse;
}

/* @overload each_vertex
 *
 * Iterates on all vertices in +graph+.
 *
 * @yieldparam [Object] vertex
 */
static
VALUE graph_each_vertex(VALUE self)
{
    RubyGraph& graph = graph_wrapped(self);

    vertex_iterator begin, end;
    tie(begin, end) = vertices(graph);

    for (vertex_iterator it = begin; it != end;)
    {
	VALUE vertex = graph[*it];
	++it;
	rb_yield_values(1, vertex);
    }
    return self;
}

/* @overload size
 *
 * @return [Integer] the number of vertices in +graph+
 */
static
VALUE graph_size(VALUE self)
{
    RubyGraph& graph = graph_wrapped(self);

    vertex_iterator begin, end;
    tie(begin, end) = vertices(graph);

    size_t count = 0;
    for (vertex_iterator it = begin; it != end; ++it)
	++count;
    return UINT2NUM(count);
}


/* @overload insert(vertex)
 *
 * Adds a new vertex to this graph
 *
 * @param [BGL::Vertex] the new vertex
 * @return [self]
 */
static
VALUE graph_insert(VALUE self, VALUE vertex)
{
    RubyGraph&	graph = graph_wrapped(self);
    graph_map&  vertex_graphs = *vertex_descriptor_map(vertex, true);

    graph_map::iterator it;
    bool inserted;
    tie(it, inserted) = vertex_graphs.insert( make_pair(self, static_cast<void*>(0)) );
    if (inserted)
	it->second = add_vertex(vertex, graph);

    return self;
}

/* @overload remove(vertex)
 * 
 * Removes a vertex from this graph. It simply does nothing if the vertex is not
 * part of the graph
 *
 * @param [BGL::Vertex] the vertex that should be removed
 * @return [self]
 */
static
VALUE graph_remove(VALUE self, VALUE vertex)
{
    RubyGraph&	graph = graph_wrapped(self);
    graph_map*  vertex_graphs = vertex_descriptor_map(vertex, false);
    if (!vertex_graphs)
        return self;

    graph_map::iterator it = vertex_graphs->find(self);
    if (it == vertex_graphs->end())
	return self;

    clear_vertex(it->second, graph);
    remove_vertex(it->second, graph);
    vertex_graphs->erase(it);
    return self;
}

/* @overload clear
 *
 * Removes all vertices from this graph
 *
 * @return [self]
 */
static
VALUE graph_clear(VALUE self)
{
    RubyGraph&	graph = graph_wrapped(self);

    vertex_iterator begin, end;
    tie(begin, end) = vertices(graph);
    for (vertex_iterator it = begin; it != end; ++it)
    {
        VALUE vertex_value = graph[*it];
        graph_map& vertex_graphs = *vertex_descriptor_map(vertex_value, false);

        graph_map::iterator it2 = vertex_graphs.find(self);
        vertex_graphs.erase(it2);
    }
    graph.clear();
    return self;
}

/* @overload include?(vertex)
 *
 * @return [Boolean] true if +vertex+ is part of this graph.
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

/* @overload link(source, target, info)
 *
 * Adds an edge in this graph
 *
 * @param [BGL::Vertex] source the source vertex. It gets added to the graph if
 *   it is not already.
 * @param [BGL::Vertex] target the target vertex. It gets added to the graph if
 *   it is not already.
 * @param [Object] info the edge information. It can be retrieved later with
 *   {BGL::Vertex#[]}
 * @return [self]
 */
static
VALUE graph_link(VALUE self, VALUE source, VALUE target, VALUE info)
{
    RubyGraph& graph = graph_wrapped(self);

    vertex_descriptor 
	s = graph_ensure_inserted_vertex(self, source),
	t = graph_ensure_inserted_vertex(self, target);

    bool inserted = add_edge(s, t, EdgeProperty(info), graph).second;
    if (! inserted)
	rb_raise(rb_eArgError, "edge already exists");

    return self;
}

/* @overload unlink(source, target)
 *
 * Removes an edge from this graph. Does nothing if the edge does not exist
 *
 * @param [BGL::Vertex] source the source of the edge
 * @param [BGL::Vertex] target the target of the edge
 * @return [self]
 */
static
VALUE graph_unlink(VALUE self, VALUE source, VALUE target)
{
    RubyGraph& graph = graph_wrapped(self);

    vertex_descriptor s, t; bool exists;
    tie(s, exists) = rb_to_vertex(source, self);
    if (! exists) return self;
    tie(t, exists) = rb_to_vertex(target, self);
    if (! exists) return self;
    if (edge(s, t, graph).second)
        remove_edge(s, t, graph);
    return self;
}

/* @overload linked?(source, target)
 *
 * Checks for the existence of an edge
 *
 * @param [BGL::Vertex] source the edge source vertex
 * @param [BGL::Vertex] target the edge target vertex
 * @return [Boolean]
 */
static
VALUE graph_linked_p(VALUE self, VALUE source, VALUE target)
{
    RubyGraph& graph = graph_wrapped(self);

    vertex_descriptor s, t; bool exists;
    tie(s, exists) = rb_to_vertex(source, self);
    if (! exists) return Qfalse;
    tie(t, exists) = rb_to_vertex(target, self);
    if (! exists) return Qfalse;
    return edge(s, t, graph).second ? Qtrue : Qfalse;
}

/* @overload each_edge { |source, target, info| ... }
 *
 * Iterates on all edges in this graph.
 *
 * @yieldparam [BGL::Vertex] source the edge source
 * @yieldparam [BGL::Vertex] target the edge target
 * @yieldparam [Object] info the information associated with the edge
 * @return [self]
 */
static
VALUE graph_each_edge(VALUE self)
{
    RubyGraph& graph = graph_wrapped(self);

    edge_iterator	  begin, end;
    tie(begin, end) = edges(graph);

    for (edge_iterator it = begin; it != end;)
    {
	VALUE from	= graph[source(*it, graph)];
	VALUE to	= graph[target(*it, graph)];
	VALUE data	= graph[*it].info;
	++it;

	rb_yield_values(3, from, to, data);
    }
    return self;
}




/**********************************************************************
 *  BGL::Vertex
 */

static void vertex_free(graph_map* map) { delete map; }
static void vertex_mark(graph_map* map)
{
    for (graph_map::iterator it = map->begin(); it != map->end(); ++it)
	rb_gc_mark(it->first);
}

/* Returns the graph => descriptor map for +self+ */
graph_map* vertex_descriptor_map(VALUE self, bool create)
{
    graph_map* map = 0;
    VALUE descriptors = rb_ivar_get(self, id_rb_graph_map);
    if (RTEST(descriptors))
    {
	Data_Get_Struct(descriptors, graph_map, map);
    }
    else if (create)
    {
	map = new graph_map;
	VALUE rb_map = Data_Wrap_Struct(rb_cObject, vertex_mark, vertex_free, map);
	rb_ivar_set(self, id_rb_graph_map, rb_map);
    }

    return map;
}

/* @overload vertex.each_graph { |graph| ... }
 *
 * Iterates on all graphs this object is part of
 *
 * @yieldparam [BGL::Graph] graph
 * @return [self]
 */
static VALUE vertex_each_graph(VALUE self)
{
    graph_map* graphs = vertex_descriptor_map(self, false);
    if (!graphs)
        return self;

    for (graph_map::iterator it = graphs->begin(); it != graphs->end();)
    {
	VALUE graph = it->first;
	// increment before calling rb_yield since the block
	// can call Graph#remove for instance
	++it;
	rb_yield_values(1, graph);
    }
    return self;
}

/* Tests whether an object is a parent of self
 *
 * @overload vertex.parent_object?(object)
 *   Tests if the object is a parent of vertex in at least one of the graphs
 *   they are included in
 *
 *   @param [BGL::Vertex] object
 *   @return [Boolean]
 *
 * @overload vertex.parent_object?(object, graph)
 *   Tests if the object is a parent of vertex in graph
 *
 *   @param [BGL::Vertex] object
 *   @param [BGL::Graph] graph
 *   @return [Boolean]
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
	RubyGraph& graph     = graph_wrapped(it->first);
	vertex_descriptor child = it->second;
	vertex_descriptor parent; bool in_graph;
	tie(parent, in_graph) = rb_to_vertex(rb_parent, it->first);

	if (in_graph && edge(parent, child, graph).second)
	    return Qtrue;
    }
    return Qfalse;
}

/* Tests whether an object is a child of self
 *
 * @overload vertex.child_object?(object)
 *   Tests if the object is a child of vertex in at least one of the graphs
 *   they are included in
 *
 *   @param [BGL::Vertex] object
 *   @return [Boolean]
 *
 * @overload vertex.child_object?(object, graph)
 *   Tests if the object is a child of vertex in graph
 *
 *   @param [BGL::Vertex] object
 *   @param [BGL::Graph] graph
 *   @return [Boolean]
 */
static VALUE vertex_child_p(int argc, VALUE* argv, VALUE self)
{ 
    swap(argv[0], self);
    return vertex_parent_p(argc, argv, self);
}

/* Tests whether there is an edge between self and another vertex
 *
 * @overload vertex.related_object?(object)
 *   Tests if there is an edge between object and vertex in at least one of the
 *   graphs they are included in
 *
 *   @param [BGL::Vertex] object
 *   @return [Boolean]
 *
 * @overload vertex.related_object?(object, graph)
 *   Tests if there is an edge in graph between object and vertex
 *
 *   @param [BGL::Vertex] object
 *   @param [BGL::Graph] graph
 *   @return [Boolean]
 */
static VALUE vertex_related_p(int argc, VALUE* argv, VALUE self)
{
    if (vertex_parent_p(argc, argv, self) == Qtrue)
	return Qtrue;
    return vertex_child_p(argc, argv, self);
}

static inline VALUE yield_single_value(VALUE value)
{
    return rb_yield_values(1, value);
}

template <bool directed>
static VALUE vertex_each_related(int argc, VALUE* argv, VALUE self)
{
    VALUE graph = Qnil;
    rb_scan_args(argc, argv, "01", &graph);

    if (NIL_P(graph))
    {
	set<VALUE> already_seen;
	for_each_graph(self, bind(for_each_adjacent_uniq<RubyGraph, directed>, _1, _2, boost::ref(already_seen)));
    }
    else
    {
	vertex_descriptor v; bool exists;
	tie(v, exists) = rb_to_vertex(self, graph);
	if (! exists)
	    return self;

	RubyGraph& g = graph_wrapped(graph);
	for_each_value(::details::vertex_range<RubyGraph, directed>::get(v, g), g, yield_single_value);
    }
    return self;
}

/* @overload each_parent_vertex { |object| ... }
 *   Iterates on all parents of self in all the graphs it is part of
 *   @yieldparam [BGL::Vertex] object
 *   @return [self]
 *
 * @overload each_parent_vertex(graph) { |object| ... }
 *   Iterates on all parents of self in graph
 *   @param [BGL::Graph] graph
 *   @yieldparam [BGL::Vertex] object
 *   @return [self]
 */
static VALUE vertex_each_parent(int argc, VALUE* argv, VALUE self)
{ return vertex_each_related<false>(argc, argv, self); }

/* @overload each_child_vertex { |object| ... }
 *   Iterates on all children of self in all the graphs it is part of
 *   @yieldparam [BGL::Vertex] object
 *   @return [self]
 *
 * @overload each_child_vertex(graph) { |object| ... }
 *   Iterates on all children of self in graph
 *   @param [BGL::Graph] graph
 *   @yieldparam [BGL::Vertex] object
 *   @return [self]
 */
static VALUE vertex_each_child(int argc, VALUE* argv, VALUE self)
{ return vertex_each_related<true>(argc, argv, self); }

/* @overload singleton_vertex?
 *
 * @return [Boolean] returns true if there are no graphs in which self is part
 *   of where it is included in an edge
 */
static VALUE vertex_singleton_p(VALUE self)
{
    graph_map::iterator it, end;
    for (tie(it, end) = vertex_descriptors(self); it != end; ++it)
    {
	RubyGraph& graph    = graph_wrapped(it->first);
	vertex_descriptor v = it->second;
	if (in_degree(v, graph) || out_degree(v, graph))
	    return Qfalse;
    }
    return Qtrue;
}

/* @overload in_degree(vertex)
 *   Returns the number of edges for which the given vertex is the target
 *
 *   @param [BGL::Vertex] vertex the vertex for which we want the number of in-edges
 *   @return [Integer]
 */
static VALUE graph_in_degree(VALUE _graph, VALUE _vertex)
{
    RubyGraph& graph = graph_wrapped(_graph);
    vertex_descriptor s; bool exists;
    tie(s, exists) = rb_to_vertex(_vertex, _graph);
    if (!exists) return INT2NUM(0);
    else return INT2NUM(in_degree(s, graph));
}

/* @overload out_degree(vertex)
 *   Returns the number of edges in which the given vertex is the source
 *
 *   @param [BGL::Vertex] vertex the vertex for which we want the number of out-edges
 *   @return [Integer]
 */
static VALUE graph_out_degree(VALUE _graph, VALUE _vertex)
{
    RubyGraph& graph = graph_wrapped(_graph);
    vertex_descriptor s; bool exists;
    tie(s, exists) = rb_to_vertex(_vertex, _graph);
    if (!exists) return INT2NUM(0);
    else return INT2NUM(out_degree(s, graph));
}

/* @overload self[child, graph]
 *
 * Get the data associated with the self => child edge in graph.
 *
 * @param [BGL::Vertex] child
 * @param [BGL::Graph] graph
 * @raise ArgumentError if there is no such edge.
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

    RubyGraph& graph = graph_wrapped(rb_graph);
    edge_descriptor e;
    tie(e, exists) = edge(source, target, graph);
    if (! exists)
	rb_raise(rb_eArgError, "no such edge in graph");

    return graph[e].info;
}

/* @overload self[child, graph] = value
 *
 * Sets the data associated with the self => child edge in graph.
 *
 * @param [BGL::Vertex] child
 * @param [BGL::Graph] graph
 * @param [Object] value
 * @raise ArgumentError if there is no such edge.
 */
static VALUE vertex_set_info(VALUE self, VALUE child, VALUE rb_graph, VALUE new_value)
{
    vertex_descriptor source, target; bool exists;

    tie(source, exists) = rb_to_vertex(self, rb_graph);
    if (! exists)
	rb_raise(rb_eArgError, "self is not in graph");
    tie(target, exists) = rb_to_vertex(child, rb_graph);
    if (! exists)
	rb_raise(rb_eArgError, "child is not in graph");

    RubyGraph& graph = graph_wrapped(rb_graph);
    edge_descriptor e;
    tie(e, exists) = edge(source, target, graph);
    if (! exists)
	rb_raise(rb_eArgError, "no such edge in graph");

    return (graph[e].info = new_value);
}

/* @overload root?(vertex)
 *
 * @param [BGL::Vertex] vertex
 * @return [Boolean] true if vertex is a root in self
 */
static VALUE graph_root_p(VALUE graph, VALUE vertex)
{
    VALUE argv[1] = { graph };
    return vertex_has_adjacent<false>(1, argv, vertex);
}

/* @overload leaf?(vertex)
 *
 * @param [BGL::Vertex] vertex
 * @return [Boolean] true if vertex is a leaf in self
 */
static VALUE graph_leaf_p(VALUE graph, VALUE vertex)
{
    VALUE argv[1] = { graph };
    return vertex_has_adjacent<true>(1, argv, vertex);
}

/* @overload root?
 *   @return [Boolean] true if self is a root in all graphs it is part of
 * 
 * @overload root?(graph)
 *   Tests whether this vertex is a root in the graph
 *   @param [BGL::Graph] graph
 *   @return [Boolean]
 */
static VALUE vertex_root_p(int argc, VALUE* argv, VALUE self)
{ return vertex_has_adjacent<false>(argc, argv, self); }


/* @overload leaf?
 *   @return [Boolean] true if self is a leaf in all graphs it is part of
 * 
 * @overload leaf?(graph)
 *   Tests whether this vertex is a leaf in the graph
 *   @param [BGL::Graph] graph
 *   @return [Boolean]
 */
static VALUE vertex_leaf_p(int argc, VALUE* argv, VALUE self)
{ return vertex_has_adjacent<true>(argc, argv, self); }

/* @overload name=(value)
 *   Set the graph's name (used for debugging purposes)
 *
 *   @param [String] value a new name for the graph
 *   @return [String]
 */
static VALUE graph_set_name(VALUE self, VALUE name)
{
    RubyGraph& graph = graph_wrapped(self);
    graph.name = StringValuePtr(name);
    return Qnil;
}

void Init_graph_algorithms();
extern "C" void Init_roby_bgl()
{
    id_rb_graph_map = rb_intern("@__bgl_graphs__");

    bglModule = rb_define_module("BGL");
    bglGraph  = rb_define_class_under(bglModule, "Graph", rb_cObject);
    rb_define_alloc_func(bglGraph, graph_alloc);

    // Functions to manipulate BGL::Vertex objects in Graphs
    rb_define_method(bglGraph, "size",    RUBY_METHOD_FUNC(graph_size), 0);
    rb_define_method(bglGraph, "insert",    RUBY_METHOD_FUNC(graph_insert), 1);
    rb_define_method(bglGraph, "remove",    RUBY_METHOD_FUNC(graph_remove), 1);
    rb_define_method(bglGraph, "include?",  RUBY_METHOD_FUNC(graph_include_p), 1);
    rb_define_method(bglGraph, "link",	    RUBY_METHOD_FUNC(graph_link), 3);
    rb_define_method(bglGraph, "unlink",    RUBY_METHOD_FUNC(graph_unlink), 2);
    rb_define_method(bglGraph, "linked?",   RUBY_METHOD_FUNC(graph_linked_p), 2);
    rb_define_method(bglGraph, "vertices",	RUBY_METHOD_FUNC(graph_vertices), 0);
    rb_define_method(bglGraph, "empty?",	RUBY_METHOD_FUNC(graph_empty_p), 0);
    rb_define_method(bglGraph, "each_vertex",	RUBY_METHOD_FUNC(graph_each_vertex), 0);
    rb_define_method(bglGraph, "each_edge",	RUBY_METHOD_FUNC(graph_each_edge), 0);
    rb_define_method(bglGraph, "root?", RUBY_METHOD_FUNC(graph_root_p), 1);
    rb_define_method(bglGraph, "leaf?", RUBY_METHOD_FUNC(graph_leaf_p), 1);
    rb_define_method(bglGraph, "in_degree",		RUBY_METHOD_FUNC(graph_in_degree), 1);
    rb_define_method(bglGraph, "out_degree",		RUBY_METHOD_FUNC(graph_out_degree), 1);
    rb_define_method(bglGraph, "clear",	RUBY_METHOD_FUNC(graph_clear), 0);
    rb_define_method(bglGraph, "name=",	RUBY_METHOD_FUNC(graph_set_name), 1);

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
    rb_define_method(bglVertex, "[]=",			RUBY_METHOD_FUNC(vertex_set_info), 3);
    rb_define_method(bglVertex, "singleton_vertex?",	RUBY_METHOD_FUNC(vertex_singleton_p), 0);

    bglReverseGraph    = rb_define_class_under(bglGraph, "Reverse", rb_cObject);
    bglUndirectedGraph = rb_define_class_under(bglGraph, "Undirected", rb_cObject);
    Init_graph_algorithms();
}

