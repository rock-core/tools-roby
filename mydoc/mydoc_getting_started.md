---
title: 1. Build the default project
tags: [getting_started]
keywords: start, introduction, begin, install, build, hello world,
last_updated: November 30, 2015
summary: "To get started with this theme, first make sure you have all the prerequisites in place; then build the theme following the sample build commands. Because this theme is set up for single sourcing projects, it doesn't follow the same pattern as most Jekyll projects (which have just a _config.yml file in the root directory)."
series: "Getting Started"
weight: 1
sidebar: mydoc_sidebar
permalink: /mydoc_getting_started/
---

{% include custom/getting_started_series.html %}
## Set up the prerequisites

Before you start installing the theme, make sure you have all of these prerequisites in place.

* **Mac computer**. If you have a Windows machine, make sure you can get a vanilla Jekyll site working before proceeding. You'll probably need Ruby and Ruby Dev Kit installed first. Also note that the shell scripts (.sh files) in this theme for automating the builds work only on a Mac. To run them on Windows, you need to convert them to BAT.  
* **[Ruby](https://www.ruby-lang.org/en/)**. On a Mac, this should already be installed. Open your Terminal and type `which ruby` to confirm. 
* **[Rubygems](https://rubygems.org/pages/download)**. This is a package manager for Ruby. Type `which gem` to confirm.
* **Text editor**: My recommendations is WebStorm (or IntelliJ). You can use another text editor. However, there are certain shortcuts and efficiencies in WebStorm (such as using Find and Replace across the project, or Markdown syntax highlighting) that I'll be noting in this documentation.

I added a page called {{site.data.mydoc_urls.mydoc_install_dependencies.link}} that explains how to install any necessary RubyGem dependencies in case you run into errors.

## Build the default project

Before you start customizing the theme, make sure you can build the theme with the default content and settings first.

1. Download the theme from the [documentation-theme-jekyll Github repository](https://github.com/tomjohnson1492/documentation-theme-jekyll) and unzip it into your ~username folder. 
    
    You can either download the theme files directly by clicking the **Download Zip** button on the right of the repo, or use git to clone the repository to your local machine. 

2. Unless you're planning to publish on Github Pages, you can delete the Gemfile. The Gemfile is only in this project to allow publishing on Github Pages

4. Install the [Jekyll](https://rubygems.org/gems/jekyll) gem.
5. In your terminal, browse to the documentation-theme-jekyll folder that you downloaded. 
6. Build the site:
   
   ```
    jekyll serve
   ```
   
7. Open a new tab in your browser and preview the site at the preview URL shown.
8. Press **Ctrl+C** in Terminal to shut down the writer's preview server.
   
   If the theme builds the outputs successfully, great. You can move on to the other sections. If you run into errors building the themes, solve them before moving on. 

## Questions

If you have questions, contact me at <a href="mailto:tomjohnson1492@gmail.com">tomjohnson1492@gmail.com</a>. My regular site is [idratherbewriting.com](http://idratherbewriting.com). I'm eager to make these installation instructions as clear as possible, so please let me know if there are areas of confusion that need clarifying.

{% include custom/getting_started_series_next.html %}




