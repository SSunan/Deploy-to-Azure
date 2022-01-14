#Create a new resource group named 'MyGeotab1' and location in 'canadacentral'
az group create --name MyGeotab1 --location canadacentral

#Start a deployment at resource group 'MyGeotab1' from a template file 'template.json' 
#using a parameter file 'template_parameters.json'
az deployment group create -g MyGeotab1 --template-file template.json --parameters template_parameters.json --verbose