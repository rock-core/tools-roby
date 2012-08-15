//  (C) Copyright Sylvain Joyeux 2006
//
// Original code from reverse_graph adaptor
//  (C) Copyright David Abrahams 2000.
//
// Distributed under the Boost Software License, Version 1.0. (See
// accompanying file LICENSE_1_0.txt or copy at
// http://www.boost.org/LICENSE_1_0.txt)

#ifndef UNDIRECTED_GRAPH_HPP
#define UNDIRECTED_GRAPH_HPP

#include <boost/graph/adjacency_iterator.hpp>
#include <boost/graph/properties.hpp>
#include <boost/static_assert.hpp>
#include "iterator_sequence.hh"
#include <boost/iterator/transform_iterator.hpp>

#include <boost/type_traits.hpp>

namespace utilmm {
    struct undirected_graph_tag { };

    /** undirected_graph creates an undirected graph from a bidirectional graph. This can allow
     * to use some undirected-graph-only algorithms on bidirectional graphs
     */
    template <class BidirectionalGraph, class GraphRef = const BidirectionalGraph&>
    class undirected_graph {
	typedef undirected_graph<BidirectionalGraph, GraphRef> Self;
	typedef boost::graph_traits<BidirectionalGraph> Traits;

	BOOST_STATIC_ASSERT(( boost::is_same<boost::bidirectional_tag, typename BidirectionalGraph::directed_category>::value ));

     public:
	typedef BidirectionalGraph base_type;

	// Constructor
	undirected_graph(GraphRef g) : m_g(g) {}

	// Graph requirements
	typedef typename Traits::vertex_descriptor vertex_descriptor;
	typedef boost::undirected_tag directed_category;
	typedef typename Traits::edge_parallel_category edge_parallel_category;
	typedef typename Traits::traversal_category traversal_category;

	// Add a 'reverse' flag to edge descriptors, so that source() and target() know what
	// needs to be done
	typedef std::pair<typename Traits::edge_descriptor, bool> edge_descriptor;
	typedef edge_descriptor (*make_undirected_edge_descriptor)(typename Traits::edge_descriptor);

	// Out edges do not need to be swapped
	static edge_descriptor make_out_edge_descriptor(typename Traits::edge_descriptor e)
	{ return std::make_pair(e, false); }
	class base_out_edge_iterator : 
	    public boost::transform_iterator<make_undirected_edge_descriptor, typename Traits::out_edge_iterator>
	{
	    typedef boost::transform_iterator<make_undirected_edge_descriptor, typename Traits::out_edge_iterator>
		base_type;

	public:
	    base_out_edge_iterator() {}
	    base_out_edge_iterator(typename Traits::out_edge_iterator e)
		: base_type(e, make_out_edge_descriptor) {}
	};

	static edge_descriptor make_in_edge_descriptor(typename Traits::edge_descriptor e)
	{ return std::make_pair(e, true); }
	class base_in_edge_iterator : 
	    public boost::transform_iterator<make_undirected_edge_descriptor, typename Traits::in_edge_iterator>
	{
	    typedef boost::transform_iterator<make_undirected_edge_descriptor, typename Traits::in_edge_iterator>
		base_type;

	public:
	    base_in_edge_iterator() {}
	    base_in_edge_iterator(typename Traits::in_edge_iterator e)
		: base_type(e, make_in_edge_descriptor) {}
	};

	// Do not swap plain edge iterators
	class edge_iterator : 
	    public boost::transform_iterator<make_undirected_edge_descriptor, typename Traits::edge_iterator>
	{
	    typedef boost::transform_iterator<make_undirected_edge_descriptor, typename Traits::edge_iterator>
		base_type;
	public:
	    edge_iterator() {}
	    edge_iterator(typename Traits::edge_iterator e)
		: base_type(e, make_out_edge_descriptor) {}
	};

	// IncidenceGraph requirements
	typedef typename Traits::degree_size_type degree_size_type;
	typedef iterator_sequence
	    < base_in_edge_iterator
	    , base_out_edge_iterator
	    > in_edge_iterator;
	typedef in_edge_iterator out_edge_iterator;

	// AdjacencyGraph requirements
	typedef iterator_sequence
	    < typename Traits::adjacency_iterator
	    , typename BidirectionalGraph::inv_adjacency_iterator
	    > adjacency_iterator;
	typedef adjacency_iterator inv_adjacency_iterator;

	// VertexListGraph requirements
	typedef typename Traits::vertex_iterator vertex_iterator;

	// EdgeListGraph requirements
	typedef typename Traits::edge_iterator   traits_edge_iterator;
	typedef typename Traits::vertices_size_type vertices_size_type;
	typedef typename Traits::edges_size_type edges_size_type;

	// More typedefs used by detail::edge_property_map, vertex_property_map
	typedef typename BidirectionalGraph::edge_property_type
	  edge_property_type;
	typedef typename BidirectionalGraph::vertex_property_type
	  vertex_property_type;
	typedef undirected_graph_tag graph_tag;

	static vertex_descriptor null_vertex()
	{ return Traits::null_vertex(); }

	// Bundled properties support
        typename boost::graph::detail::bundled_result<BidirectionalGraph,
                 edge_descriptor>::type&
        operator[](edge_descriptor x)
        { return m_g[x.first]; }

        typename boost::graph::detail::bundled_result<BidirectionalGraph,
                 edge_descriptor>::type const&
        operator[](edge_descriptor x) const
        { return m_g[x.first]; }



        typename boost::graph::detail::bundled_result<BidirectionalGraph,
                 vertex_descriptor>::type&
        operator[](vertex_descriptor x)
        { return m_g[x]; }

        typename boost::graph::detail::bundled_result<BidirectionalGraph,
                 vertex_descriptor>::type const&
        operator[](vertex_descriptor x) const
        { return m_g[x]; }


	// would be private, but template friends aren't portable enough.
     // private:
	GraphRef m_g;
    };

    template <class BidirectionalGraph>
    inline undirected_graph<BidirectionalGraph>
    make_undirected_graph(const BidirectionalGraph& g)
    {
	return undirected_graph<BidirectionalGraph>(g);
    }

    template <class BidirectionalGraph>
    inline undirected_graph<BidirectionalGraph, BidirectionalGraph&>
    make_undirected_graph(BidirectionalGraph& g)
    {
	return undirected_graph<BidirectionalGraph, BidirectionalGraph&>(g);
    }

    template <class BidirectionalGraph, class GRef>
    std::pair<typename undirected_graph<BidirectionalGraph>::vertex_iterator,
	      typename undirected_graph<BidirectionalGraph>::vertex_iterator>
    vertices(const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	return vertices(g.m_g);
    }

    template <class BidirectionalGraph, class GRef>
    std::pair<typename undirected_graph<BidirectionalGraph>::edge_iterator,
	      typename undirected_graph<BidirectionalGraph>::edge_iterator>
    edges(const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	return edges(g.m_g);
    }

    template <class BidirectionalGraph, class GRef>
    inline std::pair<typename undirected_graph<BidirectionalGraph,GRef>::out_edge_iterator,
		     typename undirected_graph<BidirectionalGraph,GRef>::out_edge_iterator>
    out_edges(const typename BidirectionalGraph::vertex_descriptor u,
	      const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	std::pair<typename BidirectionalGraph::out_edge_iterator,
		  typename BidirectionalGraph::out_edge_iterator>
		      out_edges = boost::out_edges(u, g.m_g);
	std::pair<typename BidirectionalGraph::in_edge_iterator,
		  typename BidirectionalGraph::in_edge_iterator> 
		      in_edges = boost::in_edges(u, g.m_g);

	typedef typename undirected_graph<BidirectionalGraph,GRef>::out_edge_iterator edge_iterator;
	return std::make_pair(
		edge_iterator(in_edges.first, in_edges.second, out_edges.first, out_edges.first),
		edge_iterator(in_edges.second, in_edges.second, out_edges.second, out_edges.second));
    }

    template <class BidirectionalGraph, class GRef>
    inline typename BidirectionalGraph::vertices_size_type
    num_vertices(const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	return num_vertices(g.m_g);
    }

    template <class BidirectionalGraph, class GRef>
    inline typename undirected_graph<BidirectionalGraph>::edges_size_type
    num_edges(const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	return num_edges(g.m_g);
    }

    template <class BidirectionalGraph, class GRef>
    inline typename BidirectionalGraph::degree_size_type
    out_degree(const typename BidirectionalGraph::vertex_descriptor u,
	       const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	return in_degree(u, g.m_g) + out_degree(u, g.m_g);
    }

    template <class BidirectionalGraph, class GRef>
    inline std::pair<typename BidirectionalGraph::edge_descriptor, bool>
    edge(const typename BidirectionalGraph::vertex_descriptor u,
	 const typename BidirectionalGraph::vertex_descriptor v,
	 const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	return edge(v, u, g.m_g);
    }

    template <class BidirectionalGraph, class GRef>
    inline std::pair<typename BidirectionalGraph::out_edge_iterator,
	typename BidirectionalGraph::out_edge_iterator>
    in_edges(const typename BidirectionalGraph::vertex_descriptor u,
	     const undirected_graph<BidirectionalGraph,GRef>& g)
    { return out_edges(u, g); }

    template <class BidirectionalGraph, class GRef>
    inline std::pair<typename undirected_graph<BidirectionalGraph,GRef>::adjacency_iterator,
		     typename undirected_graph<BidirectionalGraph,GRef>::adjacency_iterator>
    adjacent_vertices(const typename BidirectionalGraph::vertex_descriptor u,
		      const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	std::pair<typename BidirectionalGraph::adjacency_iterator,
		  typename BidirectionalGraph::adjacency_iterator> 
		      adjacency = boost::adjacent_vertices(u, g.m_g);
	std::pair<typename BidirectionalGraph::inv_adjacency_iterator,
		  typename BidirectionalGraph::inv_adjacency_iterator>
		      inv_adjacency = boost::inv_adjacent_vertices(u, g.m_g);

	typedef typename undirected_graph<BidirectionalGraph,GRef>::adjacency_iterator adjacency_iterator;
	return std::make_pair(
		adjacency_iterator(adjacency.first, adjacency.second, inv_adjacency.first, inv_adjacency.first),
		adjacency_iterator(adjacency.second, adjacency.second, inv_adjacency.second, inv_adjacency.second));
    }

    template <class BidirectionalGraph, class GRef>
    inline typename BidirectionalGraph::degree_size_type
    in_degree(const typename BidirectionalGraph::vertex_descriptor u,
	      const undirected_graph<BidirectionalGraph,GRef>& g)
    { return out_degree(u, g); }

    template <class Edge, class BidirectionalGraph, class GRef>
    inline typename boost::graph_traits<BidirectionalGraph>::vertex_descriptor
    source(const Edge& e, const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	if (e.second)
	    return target(e.first, g.m_g);
	else
	    return source(e.first, g.m_g);
    }

    template <class Edge, class BidirectionalGraph, class GRef>
    inline typename boost::graph_traits<BidirectionalGraph>::vertex_descriptor
    target(const Edge& e, const undirected_graph<BidirectionalGraph,GRef>& g)
    {
	if (e.second)
	    return source(e.first, g.m_g);
	else
	    return target(e.first, g.m_g);
    }


    namespace detail {

      struct undirected_graph_vertex_property_selector {
	template <class UndirectedGraph, class Property, class Tag>
	struct bind_ {
	  typedef typename UndirectedGraph::base_type Graph;
	  typedef boost::property_map<Graph, Tag> PMap;
	  typedef typename PMap::type type;
	  typedef typename PMap::const_type const_type;
	};
      };

      struct undirected_graph_edge_property_selector {
	template <class UndirectedGraph, class Property, class Tag>
	struct bind_ {
	  typedef typename UndirectedGraph::base_type Graph;
	  typedef boost::property_map<Graph, Tag> PMap;
	  typedef typename PMap::type type;
	  typedef typename PMap::const_type const_type;
	};
      };

    } // namespace detail

    /** This class adapts a property map on the edges of a graph to a property map
     * on the edges of the corresponding undirected graph */
    template<typename PropertyMap>
    class undirected_property_map 
    { 
    public:
	undirected_property_map(PropertyMap pmap)
	    : m_map(pmap) {}

	PropertyMap& map() { return m_map; }
	PropertyMap const& map() const { return m_map; }

    private:
	PropertyMap m_map;
    };

    template<typename PropertyMap, typename EdgeDescriptor, typename ValueType>
    void put(undirected_property_map<PropertyMap>& map, 
	    EdgeDescriptor e, ValueType value)
    { put(map.map(), e.first, value); }
    template<typename PropertyMap, typename EdgeDescriptor>
    typename boost::property_traits<PropertyMap>::value_type
	get(undirected_property_map<PropertyMap> const& map, 
	    EdgeDescriptor e)
    { return get(map.map(), e.first); }

    template<typename PropertyMap>
    undirected_property_map<PropertyMap> make_undirected_edge_map(PropertyMap pmap)
    { return undirected_property_map<PropertyMap>(pmap); }


} // namespace utilmm

// Include specialization in the boost namespace
namespace boost {
    template<typename PropertyMap>
    struct property_traits< utilmm::undirected_property_map<PropertyMap> >
	: property_traits<PropertyMap> {};

    template <>
    struct vertex_property_selector<utilmm::undirected_graph_tag> {
	typedef utilmm::detail::undirected_graph_vertex_property_selector type;
    };

    template <>
    struct edge_property_selector<utilmm::undirected_graph_tag> {
	typedef utilmm::detail::undirected_graph_edge_property_selector type;
    };

    namespace detail {
	template<typename BidirGraph, typename GRef, typename Property>
	struct get_property_map_type { };
	template<typename BidirGraph, typename Property>
	struct get_property_map_type<BidirGraph, const BidirGraph&, Property>
	{ typedef typename property_map<BidirGraph, Property>::const_type type; };
	template<typename BidirGraph, typename Property>
	struct get_property_map_type<BidirGraph, BidirGraph&, Property>
	{ typedef typename property_map<BidirGraph, Property>::type type; };
    }

    template <class BidirGraph, class GRef, class Property>
    typename detail::get_property_map_type<BidirGraph, GRef, Property>::type
    get(Property p, utilmm::undirected_graph<BidirGraph,GRef>& g)
    {
      return get(p, g.m_g);
    }

    template <class BidirGraph, class GRef, class Property>
    typename detail::get_property_map_type<BidirGraph, GRef, Property>::type
    get(Property p, const utilmm::undirected_graph<BidirGraph,GRef>& g)
    {
      return get(p, g.m_g);
    }

    template <class BidirectionalGraph, class GRef, class Property, class Key>
    typename property_traits<
      typename property_map<BidirectionalGraph, Property>::const_type
    >::value_type
    get(Property p, const utilmm::undirected_graph<BidirectionalGraph,GRef>& g, const Key& k)
    {
      return get(p, g.m_g, k);
    }

    template <class BidirectionalGraph, class GRef, class Property, class Key, class Value>
    void
    put(Property p, const utilmm::undirected_graph<BidirectionalGraph,GRef>& g, const Key& k,
	const Value& val)
    {
      put(p, g.m_g, k, val);
    }

    template<typename BidirectionalGraph, typename GRef, typename Tag,
	     typename Value>
    inline void
    set_property(const utilmm::undirected_graph<BidirectionalGraph,GRef>& g, Tag tag, 
		 const Value& value)
    {
      set_property(g.m_g, tag, value);
    }

    template<typename BidirectionalGraph, typename GRef, typename Tag>
    inline
    typename graph_property<BidirectionalGraph, Tag>::type
    get_property(const utilmm::undirected_graph<BidirectionalGraph,GRef>& g, Tag tag)
    {
      return get_property(g.m_g, tag);
    }

} // namespace boost

#endif
