$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "billing/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "billing"
  s.version     = Billing::VERSION
  s.authors     = ["Alex Vangelov"]
  s.email       = ["email@data.bg"]
  s.homepage    = "http://extface.com"
  s.summary     = "Billing for Rails 4 app"
  s.description = "Provides billing for an ActiveRecord model"
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.rdoc"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency "rails", ">= 4.0.5"
  s.add_dependency "money-rails"
  s.add_dependency "paper_trail"
  s.add_dependency "resque"
  
  s.add_development_dependency "sqlite3"
end
