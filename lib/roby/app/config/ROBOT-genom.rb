# Add Genom-specific configuration here

Roby::State.genom do |g|
    # The list of modules to load
    # g.using :mod1, mod2

    # The list of configuration blocks to ignore
    # g.ignore :mod2, :mod3

    # Per-module configuration
    # g.mod1 do |m|
    #	m.device = "/dev/null"
    # end
    #
    # g.mod3 do |m|
    #	
    # end
end
