#!/usr/bin/env python

# This script is used to load goods nomenclatures and their descriptions as part of
# tasks to populate the Stop Press Notice news items
#
# You can call it with bin/fetch-commodities
#
# It will print a markdown table

import requests

url = "https://staging.trade-tariff.service.gov.uk"


# Fetch the type of the goods nomenclature via an HTML search and follow the location
# to know whether our link should be:
# - a chapter
# - a heading
# - a subheading
# - a commodity
# Subsequently, fetch the description of the goods nomenclature via the API
# and return the link and description based on the type
def fetch_goods_nomenclature_link_and_description(commodity_code):
    search_url = url + "/search?q={}".format(commodity_code)
    request = requests.get(search_url, allow_redirects=True)
    # Fetch the last two path parts /commodities/0101210000
    location = request.url.split("/")[-2:]
    location = "/".join(location)
    api_location = "/api/v2/{}".format(location)
    ui_location = "/{}".format(location)
    request = requests.get(url + api_location, allow_redirects=True)
    description = request.json()["data"]["attributes"]["description"]

    # Needs to be production as this goes into a stop press notice
    path = "https://www.trade-tariff.service.gov.uk{}".format(ui_location)
    link = '<a href="{}" target="_blank">{}</a>'.format(path, commodity_code)

    return [link, description]


if __name__ == "__main__":
    print("| Commodity Code | Description |")
    print("| -------------- | ----------- |")
    with open("commodities.txt") as f:
        commodity_codes = f.readlines()

        for commodity_code in commodity_codes:
            (
                goods_nomenclature_link,
                description,
            ) = fetch_goods_nomenclature_link_and_description(commodity_code.strip())
            print("| {} | {} |".format(goods_nomenclature_link, description))
