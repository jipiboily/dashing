require 'sinatra'
require 'sprockets'
require 'sinatra/content_for'
require 'rufus/scheduler'
require 'coffee-script'
require 'sass'
require 'json'
require 'pry'

module Dashing
  SCHEDULER = Rufus::Scheduler.start_new

  class Application < Sinatra::Base
    if Rails && Rails.root
      set :root, Rails.root
      set :root_path, '/dashing/'

      Rails.application.assets.append_path(Rails.root.join('vendor','assets','fonts'))
      Rails.application.assets.append_path(Rails.root.join('app','dashing','widgets'))
      Rails.application.assets.append_path(File.expand_path('../../javascripts', __FILE__)) # for some reasons, we can't do the same as the two previous lines

      Rails.application.config.assets.precompile += %w( dashing/application.js dashing/application.css )
      set :views, Rails.root.join('app', 'dashing', 'dashboards')
      set :widget_path, "#{settings.root}/app/dashing/widgets/"
    else
      set :root, Dir.pwd
      set :root_path, '/'

      set :sprockets,     Sprockets::Environment.new(settings.root)
      set :assets_prefix, '/assets'
      set :digest_assets, false
      ['assets/javascripts', 'assets/stylesheets', 'assets/fonts', 'assets/images', 'widgets', File.expand_path('../../javascripts', __FILE__)]. each do |path|
        settings.sprockets.append_path path
      end

      set server: 'thin'
      set :public_folder, File.join(settings.root, 'public')
      set :views, File.join(settings.root, 'dashboards')
      set :widget_path, File.join(settings.root, 'widgets')
    end

    set connections: [], history: {}
    set :default_dashboard, nil
    set :auth_token, nil

    helpers Sinatra::ContentFor
    helpers do
      def protected!
        # override with auth logic
      end
    end

    get '/events', provides: 'text/event-stream' do
      protected!
      stream :keep_open do |out|
        settings.connections << out
        out << self.latest_events
        out.callback { settings.connections.delete(out) }
      end
    end

    get '/' do
      begin
      redirect settings.root_path + (settings.default_dashboard || self.first_dashboard).to_s
      rescue NoMethodError => e
        raise Exception.new("There are no dashboards in your dashboard directory.")
      end
    end

    get '/:dashboard' do
      protected!
      erb params[:dashboard].to_sym
    end

    get '/views/:widget?.html' do
      protected!
      widget = params[:widget]
      send_file File.join(settings.widget_path, widget, "#{widget}.html")
    end

    post '/widgets/:id' do
      request.body.rewind
      body =  JSON.parse(request.body.read)
      auth_token = body.delete("auth_token")
      if !settings.auth_token || settings.auth_token == auth_token
        Dashing::Application.send_event(params['id'], body)
        204 # response without entity body
      else
        status 401
        "Invalid API key\n"
      end
    end

    class << self
      def development?
        ENV['RACK_ENV'] == 'development'
      end

      def production?
        ENV['RACK_ENV'] == 'production'
      end

      def send_event(id, body)
        body["id"] = id
        body["updatedAt"] = Time.now.to_i
        event = format_event(body.to_json)
        settings.history[id] = event
        settings.connections.each { |out| out << event }
      end

      def format_event(body)
        "data: #{body}\n\n"
      end
    end

      def latest_events
        settings.history.inject("") do |str, (id, body)|
          str << body
        end
      end


    def first_dashboard
      files = Dir[File.join(settings.views, '*.erb')].collect { |f| f.match(/(\w*).erb/)[1] }
      files -= ['layout']
      files.first
    end

    Dir[File.join(settings.root, 'lib', '**', '*.rb')].each {|file| require file }
    {}.to_json # Forces your json codec to initialize (in the event that it is lazily loaded). Does this before job threads start.

    job_path = ENV["JOB_PATH"] || 'jobs'
    files = Dir[File.join(settings.root, job_path, '/*.rb')]
    files.each { |job| require(job) }
  end
end