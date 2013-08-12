module Roby
    # This module contains some tools used in the Rakefile of both Roby core
    # and plugins
    module Rake
        # Returns the rdoc template path the documentation
        # generation should be using in Rakefile
        #
        # Two non-standard templates are provided:
        # allison[http://blog.evanweaver.com/files/doc/fauna/allison/files/README.html]
        # and jamis[http://weblog.jamisbuck.org/2005/4/8/rdoc-template]. The
        # default is jamis. Allison is nicer, but the javascript-based indexes
        # are slow given the count of classes and methods there is in Roby.
        def self.rdoc_template
            if ENV['ROBY_RDOC_TEMPLATE']
                if ENV['ROBY_RDOC_TEMPLATE'] == 'jamis'
                    Roby::Rake.info "using in-source jamis template"
                    File.expand_path('doc/styles/jamis', ROBY_ROOT_DIR)
                elsif ENV['ROBY_RDOC_TEMPLATE'] == 'allison'
                    Roby::Rake.info "using in-source allison template"
                    File.expand_path('doc/styles/allison', ROBY_ROOT_DIR)
                else
                    Roby::Rake.info "using the #{ENV['ROBY_RDOC_TEMPLATE']} template"
                    ENV['ROBY_RDOC_TEMPLATE']
                end
            end
        end

        # Invoke the given target in all plugins found in plugins/ that define it
        def self.invoke_plugin_target(target)
            Dir.new('plugins').each do |plugin_dir|
                next if plugin_dir =~ /^\.{1,2}$/

                plugin_dir = File.join('plugins', plugin_dir)
                if File.file? File.join(plugin_dir, 'Rakefile')
                    Dir.chdir(plugin_dir) do
                        task_list = `rake --tasks`.split("\n")
                        if !task_list.grep(/^rake #{target}(\s|$)/).empty?
                            if !system 'rake', target
                                raise "failed to call rake target #{target} in #{plugin_dir}"
                            end
                        end
                    end
                end
            end
        end
    end
end

