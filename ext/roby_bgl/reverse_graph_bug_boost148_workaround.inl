#include <boost/version.hpp>
namespace reverse_graph_bug_boost148_workaround
{
    template <typename Descriptor>
    struct edge_access
    {
        static Descriptor get(Descriptor d) { return d; }
    };

#if BOOST_VERSION == 104800
    template <typename Edge>
    struct edge_access< boost::detail::reverse_graph_edge_descriptor<Edge> >
    {
        static Edge get(boost::detail::reverse_graph_edge_descriptor<Edge> e)
        { return e.underlying_desc; }
    };
#endif
}

