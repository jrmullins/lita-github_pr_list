# lita-github_pr_list (Team ID)

Fork that only displays PR's for a given team ID

## Installation

Add this line to your application's Gemfile:

    gem 'lita-github_pr_list', git: 'https://github.com/jrmullins/lita-github_pr_list.git'

And then execute:

    $ bundle


## Configuration

```ruby
Lita.configure do |config|
...
  config.handlers.github_pr_list.github_organization = ENV['GITHUB_ORG']
  config.handlers.github_pr_list.github_access_token = ENV['GITHUB_TOKEN']
  config.handlers.github_pr_list.team_id = 1234567
...
end
```

## Usage

```Lita: pr list```

All of the open pull requests for a team.

