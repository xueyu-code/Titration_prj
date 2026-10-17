# Thin ESP-IDF layer: step pulses, pH ADC, BLE, NVS. No device logic here.
idf_component_register(
    SRCS "src/stepper.c"
         "src/ph_adc.c"
         "src/ble_link.c"
         "src/cal_store.c"
    INCLUDE_DIRS "include"
    REQUIRES core esp_common
    PRIV_REQUIRES esp_driver_mcpwm esp_driver_pcnt esp_driver_gpio esp_adc
                  bt nvs_flash esp_hw_support freertos log)
