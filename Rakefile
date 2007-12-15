
require 'rubygems'
gem 'echoe', '>=2.7'
require 'echoe'

e = Echoe.new("mongrel") do |p|
  p.summary = "A small fast HTTP library and server that runs Rails, Camping, Nitro and Iowa apps."
  p.author ="Zed A. Shaw"
  p.clean_pattern = ['ext/http11/*.{bundle,so,o,obj,pdb,lib,def,exp}', 'lib/*.{bundle,so,o,obj,pdb,lib,def,exp}', 'ext/http11/Makefile', 'pkg', 'lib/*.bundle', '*.gem', 'site/output', '.config', 'lib/http11.jar', 'ext/http11_java/classes', 'coverage']
  p.rdoc_pattern = ['README', 'LICENSE', 'CHANGELOG', 'COPYING', 'lib/**/*.rb', 'doc/**/*.rdoc']
  p.ignore_pattern = /^(pkg|site|projects|doc|log)|CVS|\.log/
  p.ruby_version = '>= 1.8.4'
  p.dependencies = ['gem_plugin >=0.2.3', 'cgi_multipart_eof_fix >=2.4']
  (p.rdoc_template = `allison --path`.chomp) rescue nil

  p.need_tar_gz = false
  p.need_tgz = true

  case RUBY_PLATFORM
    when /mswin/
      p.certificate_chain = ['~/gem_certificates/mongrel-public_cert.pem',
        '~/gem_certificates/luislavena-mongrel-public_cert.pem']
    else
    p.certificate_chain = ['~/p/configuration/gem_certificates/mongrel/mongrel-public_cert.pem',
    '~/p/configuration/gem_certificates/evan_weaver-mongrel-public_cert.pem']
  end

  p.eval = proc do
    case RUBY_PLATFORM
    when /mswin/
      extensions.clear
      self.files += ['lib/http11.so']
      self.platform = Gem::Platform::WIN32
    when /java/
      extensions.clear
      self.files += ['lib/http11.jar']
      self.platform = 'jruby'
    else
      add_dependency('daemons', '>= 1.0.3')
      add_dependency('fastthread', '>= 1.0.1')
    end
  end

end

#### Ragel builder

desc "Rebuild the Ragel sources"
task :ragel do
  Dir.chdir "ext/http11" do
    target = "http11_parser.c"
    File.unlink target if File.exist? target
    sh "ragel http11_parser.rl | rlgen-cd -G2 -o #{target}"
    raise "Failed to build C source" unless File.exist? target
  end
  Dir.chdir "ext/http11" do
    target = "../../ext/http11_java/org/jruby/mongrel/Http11Parser.java"
    File.unlink target if File.exist? target
    sh "ragel -J http11_parser.java.rl | rlgen-java -o #{target}"
    raise "Failed to build Java source" unless File.exist? target
  end
end

#### XXX Hack around JRuby in-process launching problem

desc "Run each test suite in isolation on JRuby"
task :test_java do
  require 'jruby'
  save = JRuby.runtime.instance_config.run_ruby_in_process
  begin
    JRuby.runtime.instance_config.run_ruby_in_process = false
    Rake::Task[:test_local].invoke
  ensure
    JRuby.runtime.instance_config.run_ruby_in_process = save
  end
end

#### XXX Hack around RubyGems and Echoe for pre-compiled extensions.

def move_extensions
  Dir["ext/**/*.#{Config::CONFIG['DLEXT']}"].each { |file| mv file, "lib/" }
end

def java_classpath_arg
  # A myriad of ways to discover the JRuby classpath
  classpath = begin
    require 'java'
    # Already running in a JRuby JVM
    Java::java.lang.System.getProperty('java.class.path')
  rescue LoadError
    ENV['JRUBY_PARENT_CLASSPATH'] || ENV['JRUBY_HOME'] && FileList["#{ENV['JRUBY_HOME']}/lib/*.jar"].join(File::PATH_SEPARATOR)
  end
  classpath ? "-cp #{classpath}" : ""
end

case RUBY_PLATFORM
when /mswin/
  filename = "lib/http11.so"
  file filename do
    Dir.chdir("ext/http11") do
      ruby "extconf.rb"
      system(PLATFORM =~ /mswin/ ? 'nmake' : 'make')
    end
    move_extensions
  end
  task :compile => [filename]

when /java/
  filename = "lib/http11.jar"
  file filename do
    build_dir = "ext/http11_java/classes"
    mkdir_p build_dir
    sources = FileList['ext/http11_java/**/*.java'].join(' ')
    sh "javac -target 1.4 -source 1.4 -d #{build_dir} #{java_classpath_arg} #{sources}"
    sh "jar cf lib/http11.jar -C #{build_dir} ."
    move_extensions
  end
  task :compile => [filename]

end

#### Project-wide install and uninstall tasks

def sub_project(project, *targets)
  targets.each do |target|
    Dir.chdir "projects/#{project}" do
      unless RUBY_PLATFORM =~ /mswin/
        sh("rake #{target.to_s}") # --trace 
      end
    end
  end
end

desc "Package Mongrel and all subprojects"
task :package_all => [:package] do
  sub_project("gem_plugin", :package)
  sub_project("cgi_multipart_eof_fix", :package)
  sub_project("fastthread", :package)
  sub_project("mongrel_status", :package)
  sub_project("mongrel_upload_progress", :package)
  sub_project("mongrel_console", :package)
  sub_project("mongrel_cluster", :package)
  sub_project("mongrel_experimental", :package)
  sub_project("mongrel_service", :package) if RUBY_PLATFORM =~ /mswin/
  sh("rake java package") unless RUBY_PLATFORM =~ /java/
  # sh("rake mswin package") unless RUBY_PLATFORM =~ /mswin/
end

task :install_requirements do
  # These run before Mongrel is installed
  sub_project("gem_plugin", :install)
  sub_project("cgi_multipart_eof_fix", :install)
  sub_project("fastthread", :install)
end

desc "for Mongrel and all subprojects"
task :install => [:install_requirements] do
  # These run after Mongrel is installed
  sub_project("mongrel_status", :install)
  sub_project("mongrel_upload_progress", :install)
  sub_project("mongrel_console", :install)
  sub_project("mongrel_cluster", :install)
  # sub_project("mongrel_experimental", :install)
  sub_project("mongrel_service", :install) if RUBY_PLATFORM =~ /mswin/
end

desc "for Mongrel and all its subprojects"
task :uninstall => [:clean] do
  sub_project("mongrel_status", :uninstall)
  sub_project("cgi_multipart_eof_fix", :uninstall)
  sub_project("mongrel_upload_progress", :uninstall)
  sub_project("mongrel_console", :uninstall)
  sub_project("gem_plugin", :uninstall)
  sub_project("fastthread", :uninstall)
  # sub_project("mongrel_experimental", :uninstall)
  sub_project("mongrel_service", :uninstall) if RUBY_PLATFORM =~ /mswin/
end

desc "for Mongrel and all its subprojects"
task :clean do
  sub_project("gem_plugin", :clean)
  sub_project("cgi_multipart_eof_fix", :clean)
  sub_project("fastthread", :clean)
  sub_project("mongrel_status", :clean)
  sub_project("mongrel_upload_progress", :clean)
  sub_project("mongrel_console", :clean)
  sub_project("mongrel_cluster", :clean)
  sub_project("mongrel_experimental", :clean)
  sub_project("mongrel_service", :clean) if RUBY_PLATFORM =~ /mswin/
end

#### Site upload tasks

namespace :site do

  desc "Package and upload .gem files and .tgz files for Mongrel and all subprojects to http://mongrel.rubyforge.org/releases/"
  task :source => [:package_all] do
    rm_rf "pkg/gems"
    rm_rf "pkg/tars"
    mkdir_p "pkg/gems"
    mkdir_p "pkg/tars"

    FileList["**/*.gem"].each { |gem| mv gem, "pkg/gems" }
    FileList["**/*.tgz"].each {|tgz| mv tgz, "pkg/tars" }

    # XXX Hack, because only Luis can package for Win32 right now
    sh "cp ~/Downloads/mongrel-#{e.version}-mswin32.gem pkg/gems/"
    sh "cp ~/Downloads/mongrel_service-0.3.3-mswin32.gem pkg/gems/"
    sh "rm -rf pkg/mongrel*"
    sh "gem generate_index -d pkg"
    sh "scp -r CHANGELOG pkg/* rubyforge.org:/var/www/gforge-projects/mongrel/releases/"
    sh "svn log -v > SVN_LOG"
    sh "scp -r SVN_LOG pkg/* rubyforge.org:/var/www/gforge-projects/mongrel/releases/"
    rm "SVN_LOG"
  end

  desc "Upload the website"
  task :web do
    # Requires the 'webgem' gem
    sh "cd site; webgen; webgen; curl 'http://feed43.com/mongrel.xml' > output/rss.xml; rsync -azv --no-perms --no-times output/* rubyforge.org:/var/www/gforge-projects/mongrel/"
    puts "\nMake sure to re-run the site update 6 hours later if you updated the news. This delay is required for Feed43 to pick up the site changes."
  end

  desc "Upload the rdocs"
  task :rdoc => [:doc] do
    sh "rsync -azv --no-perms --no-times doc/* rubyforge.org:/var/www/gforge-projects/mongrel/rdoc/"
    sh "cd projects/gem_plugin; rake site:rdoc"
  end

  desc "Upload the coverage report"
  task :coverage => [:rcov] do
    sh "rsync -azv --no-perms --no-times test/coverage/* rubyforge.org:/var/www/gforge-projects/mongrel/coverage/" rescue nil
  end

  desc "Upload the website, the rdocs, and the coverage report"
  task :all => [:clean, :web, :rdoc, :coverage]

end
