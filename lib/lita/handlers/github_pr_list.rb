require "lita"
require "json"
require "octokit"
require 'action_view'
include ActionView::Helpers::DateHelper

module Lita
  module Handlers
    class GithubPrList < Handler
      def initialize(robot)
        super
      end

      def self.default_config(config)
        config.github_organization = nil
        config.github_access_token = nil
        config.comment_hook_url = nil
        config.comment_hook_event_type = nil
        config.pull_request_open_message_hook_url = nil
        config.pull_request_open_message_hook_event_type = nil
        config.team_id = nil
      end

      route(/pr list/i, :list_org_pr, command: true,
            help: { "pr list" => "List open pull requests for an organization." }
      )

      route(/^prs repo\s+(.+)/i, :list_repo_prs, command: true,
            help: { "prs repo REPO" => "List open pull requests for a repo." }
      )

      route(/prs list/i, :list_org_prs, command: true,
            help: { "prs list" => "List open pull requests for an organization." }
      )

      route(/pr add hooks/i, :add_pr_hooks, command: true,
            help: { "pr add hooks" => "Add a pr web hook to every repo in your organization." }
      )

      route(/pr remove hooks/i, :remove_pr_hooks, command: true,
            help: { "pr remove hooks" => "Remove the pr web hook from every repo in your organization." }
      )

      route(/pr alias user (\w*) (\w*)/i, :alias_user, command: true,
            help: { "pr alias user <GithubUsername> <HipchatUsername>" => "Create an alias to match a Github "\
                    "username to a Hipchat Username." }
      )

      http.post "/comment_hook", :comment_hook
      http.post "/merge_request_action", :merge_request_action
      http.post "/pull_request_open_message_hook", :pull_request_open_message_hook

      def list_org_pr(response)
        pull_requests = Lita::GithubPrList::PullRequest.new({ github_organization: github_organization,
                                                              github_token: github_access_token,
                                                              team_id: team_id,
                                                              response: response }).list
        merge_requests = redis.keys("gitlab_mr*").map { |key| redis.get(key) }

        requests = pull_requests + merge_requests
        message = "I found #{requests.count} open pull requests for #{github_organization}\n"
        response.reply("#{message}#{requests.join("\n\n")}")
      end

      def list_repo_prs(response)
        client = Octokit::Client.new(access_token: github_access_token, auto_paginate: true)

        # Get a repo
        org_name = github_organization
        repo_name = response.args[1]
        begin
          repo = client.repo "#{org_name}/#{repo_name}"
        rescue Octokit::NotFound
          response.reply("Can't find #{repo_name}")
          return
        end

        # Get the Issues/PRs
        issues = client.issues(repo.id)

        # it's a pull request if it has a pull_request field
        pull_requests = issues.select do |issue|
          issue.pull_request != nil
        end

        if pull_requests.length == 0
          response.reply("No pull requests found for #{repo_name}")
          return
        end

        # Build a msg
        msgs = ["#{org_name}/#{repo_name} - #{repo.html_url}"]

        msgs += pull_requests.map do |pr|
          pr_title = pr.title
          pr_owner = pr.user.login
          pr_how_old = time_ago_in_words(pr.created_at) + ' ago'
          "##{pr.number} #{pr.title} - (#{pr.user.login} - #{pr_how_old})"
        end

        msg = msgs.join "\n"

        response.reply(msg)
      end

      def list_org_prs(response)
        client = Octokit::Client.new(access_token: github_access_token, auto_paginate: true)

        org_name = github_organization
        team_id = team_id

        repos = client.team_repositories team_id
        if repos.length == 0
          response.reply("No repos found for team #{team_id}")
          return
        end

        repo_msgs = []

        repos.each do |repo|
          issues = client.issues(repo.id)

          # it's a pull request if it has a pull_request field
          pull_requests = issues.select do |issue|
            issue.pull_request != nil
          end

          if pull_requests.length == 0
            next
          end

          msgs = ["#{repo.name} - #{repo.html_url}"]

          msgs += pull_requests.map do |pr|
            pr_title = pr.title
            pr_owner = pr.user.login
            pr_how_old = time_ago_in_words(pr.created_at) + ' ago'
            "##{pr.number} #{pr.title} - (#{pr.user.login} - #{pr_how_old})"
          end

          msg = msgs.join "\n"
          repo_msgs << msg
        end

        outputMsg = repo_msgs.join "\n- - - - - - - - - -\n"
        response.reply(outputMsg)
      end

      def alias_user(response)
        Lita::GithubPrList::AliasUser.new({ response:response, redis: redis }).create_alias
      end

      def comment_hook(request, response)
        message = Lita::GithubPrList::CommentHook.new({ request: request, response: response, redis: redis, github_organization: github_organization, github_token: github_access_token}).message
        message_rooms(message, response)
      end

      def pull_request_open_message_hook(request, response)
        message = Lita::GithubPrList::PullRequestOpenMessageHook.new({ request: request, response: response, redis: redis }).message
        message_rooms(message, response)
      end

      def message_rooms(message, response)
        rooms = Lita.config.adapters.hipchat.rooms
        rooms ||= [:all]
        rooms.each do |room|
          target = Source.new(room: room)
          robot.send_message(target, message) unless message.nil?
        end

        response.body << "Nothing to see here..."
      end

      def add_pr_hooks(response)
        hook_info.each_pair do |key, val|
          Lita::GithubPrList::WebHook.new(github_organization: github_organization, github_token: github_access_token,
                                web_hook: val[:hook_url], response: response, event_type: val[:event_type]).add_hooks
        end
      end

      def remove_pr_hooks(response)
        hook_info.each_pair do |key, val|
          Lita::GithubPrList::WebHook.new(github_organization: github_organization, github_token: github_access_token,
                            web_hook: val[:hook_url], response: response, event_type: val[:event_type]).remove_hooks
        end
      end

      def merge_request_action(request, response)
        payload = JSON.parse(request.body.read)
        if payload["object_kind"] == "merge_request"
          attributes = payload["object_attributes"]
          Lita::GithubPrList::MergeRequest.new({ id: attributes["id"],
                                                 title: attributes["title"],
                                                 state: attributes["state"],
                                                 redis: redis }).handle
        end
      end

    private

      def github_organization
        Lita.config.handlers.github_pr_list.github_organization
      end

      def github_access_token
        Lita.config.handlers.github_pr_list.github_access_token
      end

      def team_id
        Lita.config.handlers.github_pr_list.team_id
      end

      def hook_info
        { comment_hook: { hook_url: comment_hook_url, event_type: comment_hook_event_type },
          pull_request_open_message_hook: { hook_url: pull_request_open_message_hook_url, event_type: pull_request_open_message_hook_event_type } }
      end

      def comment_hook_url
        Lita.config.handlers.github_pr_list.comment_hook_url
      end

      def comment_hook_event_type
        Lita.config.handlers.github_pr_list.comment_hook_event_type
      end

      def pull_request_open_message_hook_url
        Lita.config.handlers.github_pr_list.pull_request_open_message_hook_url
      end

      def pull_request_open_message_hook_event_type
        Lita.config.handlers.github_pr_list.pull_request_open_message_hook_event_type
      end
    end
    Lita.register_handler(GithubPrList)

  end
end
