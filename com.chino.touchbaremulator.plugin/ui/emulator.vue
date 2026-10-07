<template>
  <v-container>
    <v-row>
      <v-col cols="12">
        <div class="mx-2">Touch Bar Emulator</div>
      </v-col>
    </v-row>
  </v-container>
</template>

<script>
export default {
  props: {
    // FlexDesigner injects the key’s model (style/data/etc.) here.
    modelValue: { type: Object, required: true },
  },
  emits: ['update:modelValue'],
  mounted() {
    // Optional: sanity ping
    this.$fd?.info?.('TouchbarEmulator UI mounted');
  },
};
</script>

<style scoped></style>
