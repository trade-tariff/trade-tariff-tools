# trade-tariff-tools

This repo is used as a wastebasket for general workflows and scripts that the tariff team need as part of our release and other processes

### bin/fetch-commodities

In order to run this script you will need the [requests library](https://pypi.org/project/requests/) and a relatively recent version of python (I'm on 3.11.4)

I installed requests by running:

```shell
pip install requests
```

And run the script with:

```shell
./fetch-commodities test-commodities.txt
```

This should print a markdown table you can copy into your Stop Press Notice

For example, this will produce:

| Commodity Code | Description |
| -------------- | ----------- |
| [3824999214](https://www.trade-tariff.service.gov.uk/commodities/3824999214#export) | Other |
| [1516209831](https://www.trade-tariff.service.gov.uk/commodities/1516209831#export) | Consigned from the United Kingdom |
| [1516209822](https://www.trade-tariff.service.gov.uk/commodities/1516209822#export) | Consigned from the United Kingdom |
| [1516209823](https://www.trade-tariff.service.gov.uk/commodities/1516209823#export) | Consigned from China |
| [1516209832](https://www.trade-tariff.service.gov.uk/commodities/1516209832#export) | Consigned from China |
| [1518009122](https://www.trade-tariff.service.gov.uk/commodities/1518009122#export) | Consigned from the United Kingdom |
| [1518009123](https://www.trade-tariff.service.gov.uk/commodities/1518009123#export) | Consigned from China |
| [1518009131](https://www.trade-tariff.service.gov.uk/commodities/1518009131#export) | Consigned from the United Kingdom |
