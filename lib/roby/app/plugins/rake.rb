require 'roby/app/rake'

module Roby
    module Rake
        ROBY_ROOT_DIR = ENV['ROBY_ROOT_DIR']

        def self.plugin_doc(name)
            require 'rake/rdoctask'

            ::Rake::RDocTask.new("docs") do |rdoc|
                rdoc.options << "--accessor" << "attribute" << "--accessor" << "attr_predicate"
                rdoc.rdoc_dir = "#{ROBY_ROOT_DIR}/doc/html/plugins/#{name}"

                yield(rdoc)
            end
        end
    end
end

