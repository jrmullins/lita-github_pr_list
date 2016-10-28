require "octokit"
require 'action_view'
include ActionView::Helpers::DateHelper

module Lita
  module GithubPrList
    class PullRequest
      attr_accessor :github_client, :github_organization, :github_pull_requests, :response, :team_id

      def initialize(params = {})
        self.response = params.fetch(:response, nil)
        github_token = params.fetch(:github_token, nil)
        self.github_organization = params.fetch(:github_organization, nil)
        self.team_id =params.fetch(:team_id, nil)
        self.github_pull_requests = []

        raise "invalid params in #{self.class.name}" if response.nil? || github_token.nil? || github_organization.nil? || team_id.nil?

        self.github_client = Octokit::Client.new(access_token: github_token, auto_paginate: true)
      end

      def list
        get_pull_requests
        build_summary
      end

    private
      def get_pull_requests
        # Grab the issues and sort out the pull request issues by repos name
        threads = []
        github_client.team_repositories(team_id).each do |repo|
          threads << Thread.new do
            github_client.list_issues(repo.id).each do |issue|
              if issue.pull_request
                issue.repository = repo
                github_pull_requests << issue
              end
            end
          end
        end
        threads.map(&:join)
      end

      def build_summary
        github_pull_requests.sort { |a,b| DateTime.parse(a.updated_at) <=> DateTime.parse(b.updated_at) }.map do |pr_issue|
          "#{pr_issue.repository.name}\t#{pr_issue.user.login}\t#{pr_issue.title} #{pr_issue.pull_request.html_url}\nLast Updated #{time_ago_in_words(Time.parse(pr_issue.updated_at)) ago}"
        end
      end

      def repo_status(repo_full_name, issue)
        issue.body = "" if issue.body.nil?
        status_object = Lita::GithubPrList::Status.new(comment: ":new: " + issue.body)
        status = status_object.comment_status
        comments(repo_full_name, issue.number).each do |c|
          status = status_object.update(c.body)
        end
        status[:list]
      end

      def comments(repo_full_name, issue_number, options = nil)
        github_options = options || { direction: 'asc', sort: 'created' }
        github_client.issue_comments(repo_full_name, issue_number, github_options)
      end
    end
  end
end
