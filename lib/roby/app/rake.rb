require 'roby/support'

module Roby
    # This module contains some tools used in the Rakefile of both Roby core
    # and plugins
    module Rake
        extend Logger::Hierarchy
        extend Logger::Forward

        # Returns the rdoc template path the documentation
        # generation should be using in Rakefile
        #
        # The default template is allison, using the gem-provided allison if
        # present and falling back to the one in-source. If the RDOC_TEMPLATE
        # environment variable is defined, use that template instead, with the
        # special value of 'jamis' using the in-source jamis template.
        def self.rdoc_template
            result = nil
            if ENV['RDOC_TEMPLATE']
                result = if ENV['RDOC_TEMPLATE'] == 'jamis'
                             Roby::Rake.info "using in-source jamis template"
                             File.expand_path('doc/styles/jamis')
                         elsif ENV['RDOC_TEMPLATE'] == 'allison'
                             Roby::Rake.info "using in-source allison template"
                             File.expand_path('doc/styles/allison')
                         else
                             Roby::Rake.info "using the #{ENV['RDOC_TEMPLATE']} template"
                             ENV['RDOC_TEMPLATE']
                         end
            else
                allison_path = `allison --path`.chomp.chomp
                result = if allison_path.empty?
                             Roby::Rake.info "using in-source allison template"
                             File.expand_path('doc/styles/allison')
                         else
                             Roby::Rake.info "using the allison gem at #{allison_path}"
                             allison_path
                         end
            end

            result
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
                            system 'rake', target
                        end
                    end
                end
            end
        end
    end
end

