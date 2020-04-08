# frozen_string_literal: true

require "roby/app/rake"

module Roby
    module Rake
        ROBY_ROOT_DIR = ENV["ROBY_ROOT_DIR"]

        def self.plugin_doc(name)
            require "rdoc/task"

            RDoc::Task.new("docs") do |rdoc|
                rdoc.rdoc_dir = "#{ROBY_ROOT_DIR}/doc/html/plugins/#{name}"

                yield(rdoc)
            end
        rescue LoadError => e
            STDERR.puts "cannot generate documentation for #{name}:"
            STDERR.puts "  #{e.message}"
        end
    end
end
