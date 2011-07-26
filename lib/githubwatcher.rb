require 'yaml' unless defined?(YAML)
require "githubwatcher/version"
require "httparty"
require "growl"
require 'date'

YAML::ENGINE.yamler = "syck" if defined?(YAML::ENGINE)

module Githubwatcher
  extend self
  include HTTParty

  WATCH = File.expand_path("~/.githubwatcher/repos.yaml")
  DB    = File.expand_path("~/.githubwatcher/db.yaml")
  AUTH  = File.expand_path("~/.githubwatcher/auth.yaml")

  base_uri 'https://api.github.com'
  format :json

  def setup
    raise "You need to install growlnotify, use brew install growlnotify or install it from growl.info site" unless Growl.installed?
    puts "Starting GitHub Watcher..."

    unless File.exist?(WATCH)
      warn "Add the repositories you're willing to monitor editing: ~/.githubwatcher/repos.yaml"
      Dir.mkdir(File.dirname(WATCH)) unless File.exist?(File.dirname(WATCH))
      File.open(WATCH, "w") { |f| f.write ["nlalonde/githubwatcher"].to_yaml }
    end

    unless File.exist?(AUTH)
      Dir.mkdir(File.dirname(AUTH)) unless File.exist?(File.dirname(AUTH))
      File.open(AUTH, "w") { |f| f.write({'username' => 'xxx', 'password' => 'xxx'}.to_yaml) }
      raise "Add your github credentials to this file: ~/.githubwatcher/auth.yaml"
    end

    @_watch = YAML.load_file(WATCH)
    @_repos = YAML.load_file(DB) if File.exist?(DB)
    if File.exist?(AUTH)
      auth_config = YAML.load_file(AUTH)
      puts auth_config.inspect
      @auth = {:username => auth_config["username"], :password => auth_config["password"]}
    end

    @commits = {}
  end

  def start!
    repos_was = repos.dup
    watch.each do |value|
      key, value = *value.split("/")
      r = get("/users/%s/repos" % key, http_options)
      r.each do |repo|
        next unless value.include?(repo["name"]) || value.include?("all")
        puts "Querying #{repo["git_url"]}..."

        found = repos_was.find { |r| r["name"] == repo["name"] }

        repo_fullname = [repo['owner']['login'],repo['name']].join('/')
        if !found
          notify(repo_fullname, "Was created")
          repos_was << repo
          repos << repo
        end

        repo_was = repos_was.find { |r| r["name"] == repo["name"] }

        if repo_was["watchers"] != repo["watchers"]
          notify(repo_fullname, "Has new #{repo["watchers"]-repo_was["watchers"]} watchers")
          repo_was["watchers"] = repo["watchers"]
        end

        if repo_was["open_issues"] != repo["open_issues"]
          notify(repo_fullname, "Has new #{repo["open_issues"]-repo_was["open_issues"]} open issues")
          repo_was["open_issues"] = repo["open_issues"]
        end

        if repo_was["pushed_at"] != repo["pushed_at"]
          repo_was["pushed_at"] = repo["pushed_at"]
          commits = new_commits(key, repo["name"])
          commits.each do |commit|
            notify(
              "#{commit[:login]} committed to #{repo['name']}",
              "#{commit[:message]}"
            )
          end
        end

        if repo_was["forks"] != repo["forks"]
          notify(repo_fullname, "Has new #{repo["forks"]-repo_was["forks"]} forks")
          repo_was["forks"] = repo["forks"]
        end

        found = repo if found
      end
    end
    Dir.mkdir(File.dirname(DB)) unless File.exist?(File.dirname(DB))
    File.open(DB, "w"){ |f| f.write @_repos.to_yaml }
  end
  alias :run :start!

  def repos
    @_repos ||= []
  end

  def watch
    @_watch ||= []
  end

  def http_options
    @auth || {}
  end

  def new_commits(user_name, repo_name)
    last_updated_at = last_update_time(user_name, repo_name)

    r = get("/repos/#{user_name}/#{repo_name}/commits?per_page=10", http_options)

    commits = r.map do |commit|
      {
        :sha => commit["sha"],
        :login => commit["author"]["login"],
        :message => commit["commit"]["message"],
        :committed_at => commit["commit"]["committer"]["date"]
      }
    end

    commits.reject! {|commit| commit[:committed_at] < last_updated_at } unless last_updated_at.nil?

    set_last_update_time(user_name, repo_name, commits.first[:committed_at]) unless commits.empty?

    commits
  end

  def last_update_time(user, repo)
    unless defined?(@commits)
      @commits = {}
      return nil
    end
    @commits[repo_key(user,repo)] ? @commits[repo_key(user,repo)][:last_updated_at] : nil
  end

  def set_last_update_time(user, repo, time)
    unless @commits[repo_key(user,repo)]
      @commits[repo_key(user,repo)] = {}
    end
    @commits[repo_key(user,repo)][:last_updated_at] = time
  end

  def repo_key(user, repo)
    "#{user}/#{repo}"
  end

  def notify(title, text)
    Growl.notify text, :title => title, :icon => File.expand_path("../../images/icon.png", __FILE__); sleep 0.2
    puts "=> #{title}: #{text}"
  end
end