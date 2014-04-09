require "open3"
require "json"
require "yaml"

module BrowserifyRails
  class BrowserifyProcessor < Tilt::Template
    BROWSERIFY_CMD = "./node_modules/.bin/browserify".freeze

    def use_config?(logical_path)
      @configuration.has_key?(logical_path)
    end

    def prepare
      @configuration = YAML::load(File.read(File.join(Rails.root, 'config', 'browserify.yml')))
    end

    def evaluate(context, locals, &block)
      if use_config?(context.logical_path) || should_browserify? && commonjs_module?
        asset_dependencies(context.environment.paths).each do |path|
          context.depend_on(path)
        end

        browserify(context.logical_path)
      else
        data
      end
    end

    private

    def should_browserify?
      Rails.application.config.browserify_rails.paths.any? do |path_spec|
        path_spec === file
      end
    end

    # Is this a commonjs module?
    #
    # Be here as strict as possible, so that non-commonjs files are not
    # preprocessed.
    def commonjs_module?
      data.to_s.include?("module.exports") || dependencies.length > 0
    end

    # This primarily filters out required files from node modules
    #
    # @return [<String>] Paths of dependencies, that are in asset directories
    def asset_dependencies(asset_paths)
      dependencies.select do |path|
        path.start_with?(*asset_paths)
      end
    end

    # @return [<String>] Paths of files, that this file depends on
    def dependencies
      @dependencies ||= run_browserify("--list").lines.map(&:strip).select do |path|
        # Filter the temp file, where browserify caches the input stream
        File.exists?(path)
      end
    end

    def browserify(logical_path)
      if Rails.application.config.browserify_rails.source_map_environments.include?(Rails.env)
        options = "-d"
      else
        options = ""
      end

      if use_config?(logical_path)
        options += " " + @configuration[logical_path].keys.collect { |key|
          "--#{key} #{@configuration[logical_path][key][0]}"
        }.join(" ")
      end

      run_browserify(options)
    end

    def browserify_cmd
      cmd = File.join(Rails.root, BROWSERIFY_CMD)

      if !File.exist?(cmd)
        raise BrowserifyRails::BrowserifyError.new("browserify could not be found at #{cmd}. Please run npm install.")
      end

      cmd
    end

    # Run browserify with `data` on standard input.
    #
    # We are passing the data via stdin, so that earlier preprocessing steps are
    # respected. If you had, say, an "application.js.coffee.erb", passing the
    # filename would fail, because browserify would read the original file with
    # ERB tags and fail. By passing the data via stdin, we get the expected
    # behavior of success, because everything has been compiled to plain
    # javascript at the time this processor is called.
    #
    # @raise [BrowserifyRails::BrowserifyError] if browserify does not succeed
    # @param options [String] Options for browserify
    # @return [String] Output on standard out
    def run_browserify(options)
      command = "#{browserify_cmd} #{options}"
      directory = File.dirname(file)
      stdout, stderr, status = Open3.capture3(command, stdin_data: data, chdir: directory)

      if !status.success?
        raise BrowserifyRails::BrowserifyError.new("Error while running `#{command}`:\n\n#{stderr}")
      end

      stdout
    end
  end
end
