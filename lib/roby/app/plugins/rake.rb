require 'roby/app/rake'

module Roby
    module Rake
        ROBY_ROOT_DIR = ENV['ROBY_ROOT_DIR']

        def self.plugin_doc(name)
            require 'rake/rdoctask'

            ::Rake::RDocTask.new("docs") do |rdoc|
                rdoc.options << "--inline-source" << "--accessor" << "attribute" << "--accessor" << "attr_predicate"
                rdoc.rdoc_dir = "#{ROBY_ROOT_DIR}/doc/rdoc/plugins/#{name}"
                rdoc.template = Roby::Rake.rdoc_template

                yield(rdoc)
            end
        end
    end
end

