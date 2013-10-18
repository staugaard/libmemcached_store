# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = 'rails2_libmemcached_store'
  s.version = '0.3.2'

  s.authors = ['Jeffrey Hardy']
  s.email   = ['packagethief@gmail.com']
  s.summary = 'ActiveSupport::Cache wrapper for libmemcached'
  s.description = %q{An ActiveSupport cache store that uses the C-based libmemcached client through
      Evan Weaver's Ruby/SWIG wrapper, memcached. libmemcached is fast, lightweight,
      and supports consistent hashing, non-blocking IO, and graceful server failover.}
  s.homepage = 'https://github.com/staugaard/libmemcached_store'

  s.files         = Dir.glob('lib/**/*')

  s.add_development_dependency 'rake'
  s.add_dependency 'memcached'
  s.add_dependency 'activesupport', '< 3'
end
