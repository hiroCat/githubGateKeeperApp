Using the GitHub App template as a base I created this simple app that installed on a repo allows you to put a mandatory step and wait for the builds triggered to pass to be able to merge 

## Install

`bundle install` 

## Set environment variables

1. Create a copy of the `.env-example` file called `.env`.
2. Add your GitHub App's private key, app ID, and webhook secret to the `.env` file.

## Run the server

1. Run `ruby server.rb` or `rerun 'server.rb'` on the command line.
