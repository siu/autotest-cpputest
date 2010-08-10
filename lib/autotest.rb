require 'find'
require 'rbconfig'

$v ||= false
$TESTING = false unless defined? $TESTING

##
# Autotest continuously scans the files in your project for changes
# and runs the appropriate tests. Test failures are run until they
# have all passed. Then the full test suite is run to ensure that
# nothing else was inadvertantly broken.
#
# If you want Autotest to start over from the top, hit ^C once. If
# you want Autotest to quit, hit ^C twice.
#
# Plugins:
#
# Plugins are available by creating a .autotest file either in your
# project root or in your home directory. You can then write event
# handlers in the form of:
#
# Autotest.add_hook hook_name { |autotest| ... }
#
# The available hooks are listed in +ALL_HOOKS+.
#
# See example_dot_autotest.rb for more details.
#
# If a hook returns a true value, it signals to autotest that the hook
# was handled and should not continue executing hooks.
#
# Naming:
#
# Autotest uses a simple naming scheme to figure out how to map
# implementation files to test files following the Test::Unit naming
# scheme.
#
# * Test files must be stored in test/
# * Test files names must start with test_
# * Test class names must start with Test
# * Implementation files must be stored in lib/
# * Implementation files must match up with a test file named
# test_.*implementation.rb
#
# Strategy:
#
# 1. Find all files and associate them from impl <-> test.
# 2. Run all tests.
# 3. Scan for failures.
# 4. Detect changes in ANY (ruby?. file, rerun all failures + changed files.
# 5. Until 0 defects, goto 3.
# 6. When 0 defects, goto 2.

class Autotest

  RUBY19 = defined? Encoding

  T0 = Time.at 0

  ALL_HOOKS = [ :died, :green, :initialize, :interrupt, :quit,
                :ran_command, :red, :reset, :run_command, :updated, :waiting ]

  HOOKS = Hash.new { |h,k| h[k] = [] }
  unless defined? WINDOZE then
    WINDOZE = /win32/ =~ RUBY_PLATFORM
    SEP = WINDOZE ? '&' : ';'
  end

  @@discoveries = []

  ##
  # Add a proc to the collection of discovery procs. See
  # +autodiscover+.

  def self.add_discovery &proc
    @@discoveries << proc
  end

  ##
  # Automatically find all potential autotest runner styles by
  # searching your loadpath, vendor/plugins, and rubygems for
  # "autotest/discover.rb". If found, that file is loaded and it
  # should register discovery procs with autotest using
  # +add_discovery+. That proc should return one or more strings
  # describing the user's current environment. Those styles are then
  # combined to dynamically invoke an autotest plugin to suite your
  # environment. That plugin should define a subclass of Autotest with
  # a corresponding name.
  #
  # === Process:
  #
  # 1. All autotest/discover.rb files loaded.
  # 2. Those procs determine your styles (eg ["rails", "rspec"]).
  # 3. Require file by sorting styles and joining (eg 'autotest/rails_rspec').
  # 4. Invoke run method on appropriate class (eg Autotest::RailsRspec.run).
  #
  # === Example autotest/discover.rb:
  #
  # Autotest.add_discovery do
  # "rails" if File.exist? 'config/environment.rb'
  # end
  #

  def self.autodiscover
    require 'rubygems'

    Gem.find_files("autotest/discover").each do |f|
      load f
    end

    @@discoveries.map { |proc| proc.call }.flatten.compact.sort.uniq
  end

  ##
  # Initialize and run the system.

  def self.run
    new.run
  end

  attr_writer :known_files
  attr_accessor(
                :completed_re,
                :failed_results_re,
                :extra_files,
                :find_order,
                :interrupted,
                :last_mtime,
                :libs,
                :order,
                :output,
                :results,
                :sleep,
                :find_directories,
                :wants_to_quit)

  ##
  # Initialize the instance and then load the user's .autotest file, if any.

  def initialize
    # these two are set directly because they're wrapped with
    # add/remove/clear accessor methods
    @exception_list = []

    self.completed_re = /^OK/
    self.extra_files = []
    self.failed_results_re = /^(.*?):(\d+): error: (?:Failure|Error) in TEST\((.*?), (.*?)\)/
    self.find_order = []
    self.known_files = nil
    self.libs = %w(. lib).join(File::PATH_SEPARATOR)
    self.output = $stderr
    self.sleep = 1
    self.find_directories = %w(src include test tests)

    [File.expand_path('~/.autotest'), './.autotest'].each do |f|
      load f if File.exist? f
    end
  end

  ##
  # Repeatedly run failed tests, then all tests, then wait for changes
  # and carry on until killed.

  def run
    hook :initialize
    reset
    add_sigint_handler

    self.last_mtime = Time.now if $f

    loop do # ^c handler
      begin
        rerun_all_tests
        wait_for_changes
      rescue Interrupt
        break if self.wants_to_quit
        reset
      end
    end
    hook :quit
  rescue Exception => err
    hook :died, err
  end

  ##
  # Look for files to test then run the tests and handle the results.

  def run_tests
    hook :run_command

    new_mtime = self.find_files_to_test
    return unless new_mtime
    self.last_mtime = new_mtime

    cmd = "make test"
    return if cmd.empty?

    puts cmd unless $q

# TODO: what is this?
    old_sync = $stdout.sync
    $stdout.sync = true
    self.results = []
    line = []
    begin
      open("| #{cmd}", "r") do |f|
        until f.eof? do
          c = f.getc or break
          if RUBY19 then
            print c
          else
            putc c
          end
          line << c
          if c == ?\n then
            self.results << if RUBY19 then
                              line.join
                            else
                              line.pack "c*"
                            end
            line.clear
          end
        end
      end
    ensure
      $stdout.sync = old_sync
    end
    hook :ran_command
    self.results = self.results.join

    handle_results(self.results)
  end

  ##
  # Check results for failures, set the "bar" to red or green, and if
  # there are failures record this.

  def handle_results(results)
    completed = results =~ self.completed_re

    color = completed ? :green : :red
    hook color unless $TESTING
  end

  ############################################################
  # Utility Methods, not essential to reading of logic

  ##
  # Installs a sigint handler.

  def add_sigint_handler
    trap 'INT' do
      if self.interrupted then
        self.wants_to_quit = true
      else
        unless hook :interrupt then
          puts "Interrupt a second time to quit"
          self.interrupted = true
          Kernel.sleep 1.5
        end
        raise Interrupt, nil # let the run loop catch it
      end
    end
  end


  ##
  # Find the files to process, ignoring temporary files, source
  # configuration management files, etc., and return a Hash mapping
  # filename to modification time.

  def find_files
    result = {}
    targets = self.find_directories + self.extra_files
    self.find_order.clear

    targets.each do |target|
      order = []
      begin
        Find.find(target) do |f|
          Find.prune if f =~ self.exceptions

          next if test ?d, f
          next if f =~ /(swp|~|rej|orig)$/ # temporary/patch files
          next if f =~ /\.(d|o|a|so)$/ # compiled files
          next if f =~ /\/\.?#/ # Emacs autosave/cvs merge files

          filename = f.sub(/^\.\//, '')

          result[filename] = File.stat(filename).mtime rescue next
          order << filename
        end
      rescue
        next
      end
      self.find_order.push(*order.sort)
    end

    return result
  end

  ##
  # Find the files which have been modified, update the recorded
  # timestamps, and use this to update the files to test. Returns true
  # if any file is newer than the previously recorded most recent
  # file.

  def find_files_to_test(files=find_files)
    updated = files.select { |filename, mtime| self.last_mtime < mtime }

    p updated if $v unless updated.empty? || self.last_mtime.to_i == 0

    hook :updated, updated unless updated.empty? || self.last_mtime.to_i == 0

    if updated.empty? then
      nil
    else
      files.values.max
    end
  end

  ##
  # Lazy accessor for the known_files hash.

  def known_files
    unless @known_files then
      @known_files = Hash[*find_order.map { |f| [f, true] }.flatten]
    end
    @known_files
  end

  def new_hash_of_arrays
    Hash.new { |h,k| h[k] = [] }
  end

  ##
  # Rerun the tests from cold (reset state)

  def rerun_all_tests
    reset
    run_tests
  end

  ##
  # Clear all state information about test failures and whether
  # interrupts will kill autotest.

  def reset
    self.find_order.clear
    self.interrupted = false
    self.known_files = nil
    self.last_mtime = T0
    self.wants_to_quit = false

    hook :reset
  end

  ##
  # Determine and return the path of the ruby executable.

  def ruby
    ruby = ENV['RUBY']
    ruby ||= File.join(Config::CONFIG['bindir'],
                       Config::CONFIG['ruby_install_name'])

    ruby.gsub! File::SEPARATOR, File::ALT_SEPARATOR if File::ALT_SEPARATOR

    return ruby
  end

  ##
  # Sleep then look for files to test, until there are some.

  def wait_for_changes
    hook :waiting
    Kernel.sleep self.sleep until find_files_to_test
  end

  ############################################################
  # Exceptions:

  ##
  # Adds +regexp+ to the list of exceptions for find_file. This must
  # be called _before_ the exceptions are compiled.

  def add_exception regexp
    raise "exceptions already compiled" if defined? @exceptions

    @exception_list << regexp
    nil
  end

  ##
  # Removes +regexp+ to the list of exceptions for find_file. This
  # must be called _before_ the exceptions are compiled.

  def remove_exception regexp
    raise "exceptions already compiled" if defined? @exceptions
    @exception_list.delete regexp
    nil
  end

  ##
  # Clears the list of exceptions for find_file. This must be called
  # _before_ the exceptions are compiled.

  def clear_exceptions
    raise "exceptions already compiled" if defined? @exceptions
    @exception_list.clear
    nil
  end

  ##
  # Return a compiled regexp of exceptions for find_files or nil if no
  # filtering should take place. This regexp is generated from
  # +exception_list+.

  def exceptions
    unless defined? @exceptions then
      if @exception_list.empty? then
        @exceptions = nil
      else
        @exceptions = Regexp.union(*@exception_list)
      end
    end

    @exceptions
  end

  ############################################################
  # Hooks:

  ##
  # Call the event hook named +name+, executing all registered hooks
  # until one returns true. Returns false if no hook handled the
  # event.

  def hook(name, *args)
    deprecated = {
      # none currently
    }

    if deprecated[name] and not HOOKS[name].empty? then
      warn "hook #{name} has been deprecated, use #{deprecated[name]}"
    end

    HOOKS[name].any? do |plugin|
      plugin[self, *args]
    end
  end

  ##
  # Add the supplied block to the available hooks, with the given
  # name.

  def self.add_hook(name, &block)
    HOOKS[name] << block
  end
end
