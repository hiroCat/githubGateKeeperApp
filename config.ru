require 'rubygems'
require 'bundler'
require 'sinatra'
require 'octokit'
require 'dotenv/load' 
require 'json'
require 'openssl'     
require 'jwt'         
require 'time'        
require 'logger'      

Bundler.require

require "./server"
run GHAapp
