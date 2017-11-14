source 'https://rubygems.org'

gem 'rubigen', github: 'doudou/rubigen'
gem 'activesupport', '< 5.0.0', platform: [:ruby_20, :ruby_21]

gem 'metaruby', github: 'rock-core/tools-metaruby', branch: 'syskit2'

platform :mri do
    gem 'stackprof'
    gem 'rbtrace'
    group 'gui' do
        gem 'qtbindings'
    end
end
gem 'coveralls'

gemspec
