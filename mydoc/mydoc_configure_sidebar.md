---
title: 6. Configure the sidebar
tags: [getting_started]
last_updated: November 30, 2015
keywords: sidebar, accordion, yaml, iteration, for loop, navigation, attributes, conditional filtering
summary: "The sidebar and top navigation bar read their values from yml files. Understanding how the sidebar works is critical to successfully using this theme."
series: "Getting Started"
weight: 6
sidebar: mydoc_sidebar
permalink: /mydoc_configure_sidebar/
---

{% include custom/getting_started_series.html %}

## Understand how the sidebar works

In the \_data folder, the sidebars folder contains all the sidebars for your theme. You can have as many sidebars as you want. Usually you would dedicate a unique sidebar for each product.
 
As a best practice, do the following with the sidebar:
 
* List all pages in your project somewhere in a sidebar. 
* As soon as you create a new page, add it to a sidebar (so you don't forget about the page). 
* Copy and paste the existing YAML chunks (then customize them) to get the formatting right.

YAML is a markup that uses spacing and hyphens instead of tags. YAML is a superset of JSON, so you can convert from YAML to JSON and vice versa equivalently.

There are certain values in the sidebar file coded to match the theme's code. These values include the main level names (`entries`, `subcategories`, `items`, `thirdlevel`, and `thirdlevelitems`). If you change these values in the sidebar file, the navigation won't display. 

At a high level, the sidebar data structure looks like this:

```yaml
entries
  subcategories
    items
      thirdlevel
        thirdlevelitems
```

Within these levels, you add your content. You can only have two levels in the sidebar. Here's an example of the two levels:

```
Introduction
 -> Getting started
 -> Features
 -> Configuration 
   -> Options
   -> Automation
```

"Introduction" is a heading &mdash; it's the first level. Beneath it are Getting started and Features &mdash; these sub-items for the first level. 

Configuration is a heading announcing a second level. Below it are Options and Automation &mdash; these are on the second level.

You can't add more than two levels. In general, it's a best practice not to create more than two levels of navigation anyway, since it creates a paralysis of choice for the user. 

You can create different sidebars for each product in your documentation, so hopefully this should help avoid the need for deep level nesting. 

## How the code works
 
The code in the theme's sidebar.html file (in the \_includes folder) iterates through the items in the mydoc_sidebar.yml file using a Liquid `for` loop and inserts the items into HTML. Iterating over a list in a data file to populate HTML is a common technique with static site generators. 

{% include custom/getting_started_series_next.html %}