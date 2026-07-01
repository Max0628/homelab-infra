version: 2
ethernets:
  mainif:
    match:
      name: "en*"
    addresses:
      - ${ip}/24
    routes:
      - to: default
        via: ${gateway}
    nameservers:
      addresses:
        - 8.8.8.8
        - 1.1.1.1
