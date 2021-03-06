function mcb_rest_call(Url, PostJson, SuccessF, ErrorF) {
    $.ajax({
        type:"POST", url: Url, headers: { Accept : "application/json" },
        dataType: "json", contentType: "application/json",
        data: JSON.stringify(PostJson),
        success: SuccessF, error: ErrorF
    });
}

function preview_show() {
    var Req = { markup: $("textarea#message").val() };
    mcb_rest_call("/rest/post/preview", Req
      , function(data, textStatus, jqXHR){
          $("div#preview-popup").show();
          $("div#preview-content").html(data.html);
      }
      , function(jqXHR, textStatus, errorThrown){
          $("div#preview-popup").show();
          $("div#preview-content").html(textStatus+"<br/>"+errorThrown);
      });
}

function user_delete(BoardId, PostId) {
    var selected = $("input:checkbox:checked.post_select").map(function() {
        return this.value; });
    var Req = { board: BoardId, posts: selected
              , password: $('input[name="pass"]').val()
              , onlyfile: $('input[name="fileonly"]').checked()
              };
    mcb_rest_call("/rest/post/delete", Req
      , function(data, textStatus, jqXHR){
          $("div#reportbar-msg").show().html("Result: "+data.result);
      }
      , function(jqXHR, textStatus, errorThrown){
          $("div#reportbar-msg").show().html(textStatus+"<br/>"+errorThrown);
      });
}
