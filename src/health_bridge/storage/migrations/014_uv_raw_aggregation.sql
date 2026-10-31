update samples
set metadata_json = json_set(metadata_json, '$.aggregation', 'min_max_average')
where type_code = 'uv_exposure'
  and case
      when json_valid(metadata_json) then
          json_extract(metadata_json, '$.sample_kind') = 'raw_quantity'
          and json_extract(metadata_json, '$.aggregation') = 'sum'
      else 0
  end;
